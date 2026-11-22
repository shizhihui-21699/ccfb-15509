# frozen_string_literal: true

module ScoreTheft
  # 对单次认领给出研判结论。
  #
  # 决策分四档:
  #   :clear    —— 无异常。正常用车,直接通过。
  #   :review   —— 存在需要核实的疑点。转人工/要求补充材料。
  #   :reject   —— 高度疑似顶替扣分。暂缓计入,转人工复核。
  #   :evidence_insufficient —— 证据不足(如照片糊),不作不利推断。
  #
  # 「拒绝」必须同时满足三个条件,缺一不可:
  #   (a) 总分达到 decision_high;
  #   (b) 至少 reject_min_substantive_categories 个实质类别成立;
  #   (c) 要么命中硬信号(重复认领/时空矛盾/清晰照片明显不符),
  #       要么实质类别达到 3 个。
  # 这保证:单一信号、模糊照片、单纯的“数量多”都不能独自定罪。
  class Decision
    attr_reader :level, :signals, :reasons

    def initialize(level:, signals:, reasons:)
      @level = level
      @signals = signals
      @reasons = reasons
    end

    def label
      {
        clear: '无异常',
        review: '需人工核实',
        reject: '疑似顶替扣分,转人工复核',
        evidence_insufficient: '证据不足'
      }.fetch(level, level.to_s)
    end

    # 是否允许该次认领直接自动计入驾驶人记分。
    def auto_accept?
      level == :clear
    end

    # 是否要求人工介入后才能继续。
    def requires_human?
      %i[review reject evidence_insufficient].include?(level)
    end

    # 转人工复核时,即便最终认定属实,也不因此对当事人作出不利记录。
    def adverse_finding?
      level == :reject
    end
  end

  class Analyzer
    attr_reader :dataset, :policy

    def initialize(dataset, policy: Policy.new)
      @dataset = dataset
      @policy = policy
      @relations = {}
      resolver = RelationResolver.new(dataset)
      dataset.claims.each { |c| @relations[c.id] = resolver.resolve(c) }
      @collusion = CollusionIndex.new(dataset, @relations, policy)
    end

    def relation_for(claim)
      @relations.fetch(claim.id) { NO_RELATION }
    end

    # 评估单次认领。
    def assess(claim)
      person = @dataset.person(claim.person_id)
      return build_missing_result(claim) if person.nil?

      signals = Signals.new(
        dataset: @dataset, relations: @relations, collusion: @collusion,
        policy: @policy, person: person, claim: claim,
        relation: relation_for(claim)
      )
      Decision.new(
        level: decide(signals, person),
        signals: signals,
        reasons: explain(signals, person)
      )
    end

    # 为某个人在某个时间点(默认其最近一次认领)生成画像。
    def profile(person_id, anchor: nil)
      person = @dataset.person(person_id)
      return nil if person.nil?

      claims = @dataset.claims_for_person(person_id)
      anchor ||= claims.map(&:violation_at).compact.max || Time.now.utc
      ref = claims.select { |c| c.violation_at == anchor }.first || claims.last

      Signals.new(
        dataset: @dataset, relations: @relations, collusion: @collusion,
        policy: @policy, person: person,
        claim: ref, relation: ref ? relation_for(ref) : NO_RELATION
      )
    end

    private

    def decide(signals, _person)
      return :clear if benign_company_use?(signals)
      return :evidence_insufficient if evidence_insufficient?(signals)

      score = signals.total_score
      substantive = signals.substantive_categories

      if reject?(signals, score, substantive)
        :reject
      elsif score >= @policy.decision_medium ||
            substantive >= 2 ||
            signals.findings.any? { |f| f.category == :photo || f.code == :duplicate_claim }
        :review
      else
        :clear
      end
    end

    # 运营车辆(租车/车队)的正常使用:有认领、但除“与运营车辆无登记关联”
    # 这条轻微信号外没有任何其它疑点。代驾、租车人开过很多租来的车本就常见,
    # 不应被标为“证据不足”或需要核实,直接通过。
    def benign_company_use?(signals)
      vehicle = @dataset.vehicle(signals.claim.vehicle_id)
      return false if vehicle.nil? || !vehicle.company?
      return false if signals.relation.verified?

      signals.findings.all? { |f| f.code == :no_relationship }
    end

    # 证据不足的判定:
    #   - 关联已核验 → 不适用(正常用车,照片糊也不影响);
    #   - 照片可辨认 → 不适用(走正常评分);
    #   - 照片不可辨认,且除照片以外的证据连转人工的门槛都达不到
    #     → 证据不足。
    #
    # 要点:这不是“有罪但缺证据”,而是“现有材料既不足以认定、
    # 也不足以拒绝”,绝不因照片糊而推断顶替。若其它独立证据已
    # 足以转人工或拒绝(几十辆陌生车、时空矛盾等),则照常判定。
    def evidence_insufficient?(signals)
      return false if signals.relation.verified?
      return false unless signals.claim.photo.unreadable?

      signals.total_score < @policy.decision_medium
    end

    def reject?(signals, score, substantive)
      return false if score < @policy.decision_high
      return false if substantive < @policy.reject_min_substantive_categories

      # 硬信号,或三个及以上实质类别同时成立。
      signals.hard? || substantive >= 3
    end

    def explain(signals, person)
      reasons = []
      reasons << "综合风险分 #{signals.total_score}"
      if signals.relation.verified?
        reasons << "已核验关联:#{signals.relation.evidence}"
      elsif signals.relation.none?
        reasons << '查无关联'
      else
        reasons << '关联仅有无核验声明'
      end
      reasons << "实质类别 #{signals.substantive_categories} 项" if signals.substantive_categories.positive?
      reasons << "命中硬信号:#{signals.findings.select { |f| Signals::HARD_CODES.include?(f.code) }.map(&:code).join(',')}" if signals.hard?
      reasons << "本人 #{person.name} 窗口内无关联认领 #{signals.unrelated_claims.size} 次"
      reasons
    end

    def build_missing_result(claim)
      signals = Signals.new(
        dataset: @dataset, relations: @relations, collusion: @collusion,
        policy: @policy, person: Person.new(id: claim.person_id, name: '未知人员'),
        claim: claim, relation: NO_RELATION
      )
      Decision.new(level: :review, signals: signals,
                   reasons: ['认领人员信息缺失,无法自动判断,需人工核实'])
    rescue StandardError
      Decision.new(level: :review, signals: nil,
                   reasons: ['认领人员信息缺失,无法自动判断,需人工核实'])
    end
  end
end
