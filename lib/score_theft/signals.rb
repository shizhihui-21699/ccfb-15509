# frozen_string_literal: true

module ScoreTheft
  # 针对「某个人 + 某一次待评估认领」计算全部信号。
  #
  # 统计窗口以该次违法发生日(anchor)为锚点,向前回溯 policy.window_days。
  # 不用“今天”作锚点:历史案件回溯时用案发时的视角判断,避免把
  # 案发之后发生的行为算进对当事人的不利推断。
  class Signals
    # 可以直接支撑「拒绝」的硬信号。
    #
    # 注意 duplicate_claim 故意不在此列:一条违法被两人认领,只能证明
    # “其中有人撒谎”,却无法证明是哪一个。据此对双方都作不利认定,
    # 恰恰会冤枉真正的驾驶人。重复认领因此只升到「转人工」,由人工
    # 结合其它材料判断,绝不自动拒绝双方。
    HARD_CODES = %i[
      impossible_travel
      face_mismatch_strong
      extreme_unrelated_volume
    ].freeze

    attr_reader :person, :claim, :relation, :anchor, :findings, :benign_notes

    def initialize(dataset:, relations:, collusion:, policy:, person:, claim:, relation:)
      @dataset = dataset
      @relations = relations
      @collusion = collusion
      @policy = policy
      @person = person
      @claim = claim
      @relation = relation || NO_RELATION
      @anchor = claim.violation_at
      @findings = []
      @benign_notes = []

      compute!
    end

    def window_start
      @window_start
    end

    def window_end
      @window_end
    end

    # 统计窗口 = 包含本案违法时间、且本人认领记录最密集的那一个
    # 365 天滚动窗口。
    #
    # 为什么不能简单地用 [案发-365天, 案发]:分贩子的前几次认领,
    # 若只看“案发之前”,就看不到他随后继续替陌生车背分,于是早期
    # 认领全部漏网。正确口径是“存在某个包含本案的 12 个月内,此人
    # 替 N 辆陌生车认领”——这既抓住了整条行为链,也仍然可解释、
    # 可申辩(不是拿案发后的行为去倒推案发时的主观状态,而是描述
    # 当事人一个完整计分周期内的客观行为集合)。
    def window_claims
      @window_claims ||= begin
        all = @dataset.claims_for_person(@person.id).select { |c| c.violation_at }
        anchor_at = @anchor

        best = []
        all.each do |start_claim|
          s = start_claim.violation_at
          e = s + (@policy.window_days * 86_400)
          next unless anchor_at >= s && anchor_at <= e

          members = all.select { |c| c.violation_at >= s && c.violation_at <= e }
          if members.size > best.size
            best = members
            @window_start = s
            @window_end = e
          end
        end

        if best.empty?
          @window_start = anchor_at - (@policy.window_days * 86_400)
          @window_end = anchor_at
          best = all.select do |c|
            c.violation_at >= @window_start && c.violation_at <= @window_end
          end
        end

        best.sort_by(&:violation_at)
      end
    end

    def unrelated_claims
      @unrelated_claims ||= window_claims.select { |c| relation_of(c).none? }
    end

    # 仅针对私家车的无关联认领。时间集中度、批量提交等信号只应看私家车:
    # 代驾/租车人一周内开过好几辆租来的车、短期内集中处理,都是工作常态,
    # 不构成异常。
    def private_unrelated_claims
      @private_unrelated_claims ||= unrelated_claims.reject do |c|
        v = @dataset.vehicle(c.vehicle_id)
        v && v.company?
      end
    end

    def weak_claims
      @weak_claims ||= window_claims.select { |c| relation_of(c).weak? }
    end

    def verified_claims
      @verified_claims ||= window_claims.select { |c| relation_of(c).verified? }
    end

    def distinct_unrelated_vehicle_ids
      unrelated_claims.map(&:vehicle_id).uniq
    end

    def hard?
      @findings.any? { |f| HARD_CODES.include?(f.code) }
    end

    def category_scores
      scores = CATEGORY_CAPS.keys.each_with_object({}) { |k, h| h[k] = 0.0 }
      @findings.each { |f| scores[f.category] += f.weight }
      scores.each_with_object({}) do |(k, v), h|
        h[k] = [v, CATEGORY_CAPS.fetch(k)].min.round(2)
      end
    end

    def total_score
      [category_scores.values.sum, 100.0].min.round(2)
    end

    # 实质类别计数:relationship / volume / photo / collusion。
    # 仅靠 temporal + behavioral 不足以拒绝,用于拒绝档的门槛判断。
    def substantive_categories
      cat = category_scores
      %i[relationship volume photo collusion].count { |k| cat[k].positive? }
    end

    def categories_present
      category_scores.select { |_, v| v.positive? }.keys
    end

    private

    def relation_of(claim)
      @relations.fetch(claim.id, NO_RELATION)
    end

    def add(code:, category:, weight:, message:, evidence: {})
      return unless weight.positive?

      @findings << Finding.new(code: code, category: category, weight: weight,
                               message: message, evidence: evidence)
    end

    def note(message)
      @benign_notes << message
    end

    # 档位映射:低于 medium 不给分;达到 medium 给 60% 分;达到 high 给满分。
    # 台阶式便于向当事人解释“为什么触发了这一档”。
    def tier(value, medium, high, max_weight)
      return 0.0 if value < medium
      return max_weight.to_f if value >= high

      (max_weight * 0.6).round(2)
    end

    def compute!
      relationship_signal
      volume_signals
      temporal_signals
      photo_signals
      behavioral_signals
      collusion_signals
    end

    # ---- 关联核验 ---------------------------------------------------------
    def relationship_signal
      vehicle = @dataset.vehicle(@claim.vehicle_id)
      company = !vehicle.nil? && vehicle.company?

      case @relation.level
      when :verified
        note("认领人与车辆存在已核验关联(#{@relation.evidence}),属正常用车")
      when :none
        weight = company ? 8.0 : 22.0
        suffix = company ? '(运营车辆,陌生人驾驶较常见,已从轻计分)' : ''
        add(code: :no_relationship, category: :relationship, weight: weight,
            message: "认领人与该车查无任何关联#{suffix}",
            evidence: { 'vehicle' => vehicle&.plate, 'kind' => vehicle&.kind })
      when :weak
        weight = company ? 4.0 : 10.0
        add(code: :unverified_relationship, category: :relationship, weight: weight,
            message: "仅有无核验的关系声明(#{@relation.evidence}),未提供可核验材料",
            evidence: { 'vehicle' => vehicle&.plate, 'declared' => @relation.kind.to_s })
      end
    end

    # ---- 数量异常 ---------------------------------------------------------
    def volume_signals
      effective_vehicles = effective_vehicle_count
      effective_points = effective_point_total

      add(code: :vehicle_variety, category: :volume,
          weight: tier(effective_vehicles, @policy.claim_count_medium,
                       @policy.claim_count_high, 30.0),
          message: "统计窗口内为 #{effective_vehicles.round(1)} 辆无关联车辆认领过",
          evidence: { 'distinct_vehicles' => distinct_unrelated_vehicle_ids.size,
                      'effective' => effective_vehicles.round(1) })

      add(code: :point_accumulation, category: :volume,
          weight: tier(effective_points, @policy.annual_points_medium,
                       @policy.annual_points_high, 30.0),
          message: "统计窗口内在无关联车辆上累计背分 #{effective_points.round(1)} 分",
          evidence: { 'raw_points' => unrelated_claims.sum(&:points),
                      'effective' => effective_points.round(1) })

      # 极端数量:仅凭“一年替多少辆陌生私家车背分”这一条,
      # 就已超出任何正常用车的解释范围(远超 policy 高档)。
      # 这是可以独立支撑拒绝的硬信号,因为它是纯粹的行为事实,
      # 不依赖照片、不依赖对任何人的主观揣测。
      private_vehicles = distinct_unrelated_vehicle_ids.count do |vid|
        v = @dataset.vehicle(vid)
        v && !v.company?
      end
      if private_vehicles >= @policy.extreme_vehicle_count
        add(code: :extreme_unrelated_volume, category: :volume, weight: 40.0,
            message: "一年内为 #{private_vehicles} 辆互不相关的陌生私家车认领违法," \
                     '已超出正常用车的任何合理解释',
            evidence: { 'private_vehicles' => private_vehicles,
                        'threshold' => @policy.extreme_vehicle_count })
      end

      weak_vehicles = weak_claims.map(&:vehicle_id).uniq.size
      add(code: :weak_relationship_variety, category: :volume,
          weight: weak_vehicles >= 5 ? 12.0 : 0.0,
          message: "为 #{weak_vehicles} 辆仅有未核验声明的车辆认领",
          evidence: { 'weak_vehicles' => weak_vehicles })

      household_absorption_signal
    end

    # 运营车辆(租车/车队)按半辆、半分计:一个代驾或租车人开过很多车
    # 本身并不异常,不应与“替陌生私家车背分”等量齐观。
    def effective_vehicle_count
      distinct_unrelated_vehicle_ids.sum do |vid|
        v = @dataset.vehicle(vid)
        v && v.company? ? 0.5 : 1.0
      end
    end

    def effective_point_total
      unrelated_claims.sum do |c|
        v = @dataset.vehicle(c.vehicle_id)
        v && v.company? ? c.points * 0.5 : c.points
      end
    end

    # 家庭“集中背分”:某一家庭成员替「同户名下、但自己并非登记所有人/
    # 使用人的多辆车(≥2)」集中吸收了远超正常容量的分数。
    #
    # 这条信号很容易误伤最常见的正常场景(夫妻共用一辆车、一人担大部分
    # 分),所以卡得很死:必须是多辆车、本人对它们都不是登记驾驶人、
    # 且总量超过两个记分周期(24 分)。夫妻共用一车永远不会触发。
    def household_absorption_signal
      household_id = @person.household_id
      return if household_id.nil?

      members = @dataset.household_members(household_id).map(&:id)
      other_members = members - [@person.id]

      # 同户名下、登记在他人名下的私家车。
      vehicles_of_others = @dataset.vehicles.select do |v|
        !v.company? &&
          v.owners.any? { |o| other_members.include?(o.person_id) } &&
          v.owners.none? { |o| o.person_id == @person.id } &&
          v.registered_drivers.none? { |d| d.person_id == @person.id }
      end
      return if vehicles_of_others.size < 2

      ids = vehicles_of_others.map(&:id)
      relevant = @dataset.claims.select do |c|
        ids.include?(c.vehicle_id) && c.person_id == @person.id &&
          c.violation_at && c.violation_at >= window_start && c.violation_at <= window_end
      end
      mine = relevant.sum(&:points)
      return if mine <= @policy.household_point_cap

      add(code: :household_absorption, category: :volume, weight: 12.0,
          message: "本人替同户名下 #{relevant.map(&:vehicle_id).uniq.size} 辆其他家庭成员的车" \
                   "集中背分 #{mine} 分,超出正常用车容量",
          evidence: { 'mine' => mine, 'vehicles' => relevant.map(&:vehicle_id).uniq.size,
                      'cap' => @policy.household_point_cap })
    end

    # ---- 时间异常 ---------------------------------------------------------
    def temporal_signals
      count = claims_within_days(@policy.short_window_days)
      add(code: :short_window, category: :temporal,
          weight: count >= @policy.short_window_count ? 20.0 : 0.0,
          message: "#{@policy.short_window_days} 天内为 #{count} 次无关联违法认领",
          evidence: { 'count' => count })

      burst = claims_submitted_within_hours(@policy.burst_hours)
      add(code: :submission_burst, category: :temporal,
          weight: burst >= @policy.burst_count ? 18.0 : 0.0,
          message: "#{@policy.burst_hours} 小时内批量提交 #{burst} 次无关联认领",
          evidence: { 'count' => burst })

      if late_claim?
        add(code: :late_claim, category: :temporal, weight: 10.0,
            message: "违法发生 #{claim_delay_days.round} 天后才认领",
            evidence: { 'delay_days' => claim_delay_days.round })
      end

      impossible = impossible_travel_pair
      if impossible
        add(code: :impossible_travel, category: :temporal, weight: 25.0,
            message: '同一人在相近时段于相距甚远的两地分别“驾驶”,至少一次不实',
            evidence: impossible)
      end
    end

    def claims_within_days(days)
      start = @anchor - (days * 86_400)
      private_unrelated_claims.count { |c| c.violation_at >= start }
    end

    def claims_submitted_within_hours(hours)
      start = @anchor - (hours * 3_600)
      private_unrelated_claims.count { |c| c.claim_at && c.claim_at >= start }
    end

    def late_claim?
      claim_delay_days > @policy.late_claim_days
    end

    def claim_delay_days
      @claim_delay_days ||= begin
        if @claim.claim_at.nil? || @claim.violation_at.nil?
          0.0
        else
          Util.days_between(@claim.violation_at, @claim.claim_at)
        end
      end
    end

    # 时空矛盾:同一人在相近时段于相距甚远的两地分别“驾驶”。
    #
    # 注意检测范围要包含锚点之后的认领——否则同一对矛盾的两次违法,
    # 只有较晚的那次会被发现,较早的那次因为窗口不包含未来而漏判。
    # 这里对“本人所有认领中与该次认领相关的对子”做检查,既看窗口内,
    # 也看紧邻窗口之后的同类认领。
    def impossible_travel_pair
      subject = @claim
      return nil unless subject.geo?

      candidates = @dataset.claims_for_person(@person.id).select do |c|
        c.geo? && !c.equal?(subject) &&
          (Util.hours_between(c.violation_at, subject.violation_at).abs <= 2.0)
      end

      best = nil
      candidates.each do |other|
        dist = Util.haversine_km(subject.location.lat, subject.location.lon,
                                 other.location.lat, other.location.lon)
        next if dist < 200.0

        if best.nil? || dist > best['distance_km']
          best = {
            'with_claim' => other.id.to_s,
            'gap_hours' => Util.hours_between(subject.violation_at, other.violation_at).round(1),
            'distance_km' => dist.round(1),
            'locations' => [subject.location.name, other.location.name].compact
          }
        end
      end
      best
    end

    # ---- 照片证据 ---------------------------------------------------------
    # 关键:照片模糊/无人脸 → 不产生任何不利推断,只记录“证据不足”。
    def photo_signals
      photo = @claim.photo

      unless photo.readable?
        note("照片无法辨认驾驶人(#{photo.reason}),未作为不利依据")
        return
      end

      score = photo.face_match_score
      if score.nil?
        note('照片清晰但未提供人脸比对结果,不作推断')
        return
      end

      if score < @policy.face_mismatch_strong
        add(code: :face_mismatch_strong, category: :photo, weight: 40.0,
            message: "清晰照片的人脸比对相似度仅 #{format('%.2f', score)},与认领人明显不符",
            evidence: { 'score' => score })
      elsif score < @policy.face_mismatch_partial
        add(code: :face_mismatch_partial, category: :photo, weight: 18.0,
            message: "清晰照片的人脸比对相似度 #{format('%.2f', score)} 偏低,存疑",
            evidence: { 'score' => score })
      else
        note("照片人脸比对相似度 #{format('%.2f', score)},与认领人相符")
      end
    end

    # ---- 行为特征 ---------------------------------------------------------
    def behavioral_signals
      created = @person.account_created_at
      claim_ats = @dataset.claims_for_person(@person.id).map(&:claim_at).compact
      earliest = claim_ats.min
      if created && earliest
        gap = Util.days_between(created, earliest)
        if gap < @policy.new_account_days
          add(code: :new_account, category: :behavioral, weight: 15.0,
              message: "账号注册 #{gap.round} 天后即开始认领违法",
              evidence: { 'days_since_registration' => gap.round })
        end
      end

      declared = weak_claims.count(&:declared_relationship)
      if declared >= 3 && @claim.declared_relationship
        add(code: :habitual_declared_friend, category: :behavioral, weight: 10.0,
            message: "多次以“#{@claim.declared_relationship}”等未核验关系认领(共 #{declared} 次)",
            evidence: { 'count' => declared })
      end
    end

    # ---- 团伙特征 ---------------------------------------------------------
    def collusion_signals
      vehicle = @dataset.vehicle(@claim.vehicle_id)
      company = !vehicle.nil? && vehicle.company?

      claimer_count = @collusion.vehicle_claimer_count(@claim.vehicle_id)
      add(code: :vehicle_claimed_by_many, category: :collusion,
          weight: tier(claimer_count, @policy.vehicle_claimers_medium,
                       @policy.vehicle_claimers_high, 25.0),
          message: "该车被 #{claimer_count} 个互不相关的人认领过",
          evidence: { 'claimers' => claimer_count, 'vehicle' => vehicle&.plate })

      dup = @collusion.duplicate_claimers(@claim)
      if dup.size >= 2
        add(code: :duplicate_claim, category: :collusion, weight: 35.0,
            message: '同一违法记录被多人同时认领;其中至多一人属实,须人工核实,' \
                     '不能仅凭此对任一方作不利认定',
            evidence: { 'claimers' => dup.to_a.size,
                        'vehicle' => vehicle&.plate,
                        'violation_at' => Util.format_time(@claim.violation_at) })
      end

      unless company
        sharers = @collusion.device_sharers(@person.id, @claim.device_id)
        if sharers.any?
          add(code: :shared_device, category: :collusion, weight: 25.0,
              message: '与其他无关联认领人使用同一台设备提交',
              evidence: { 'other_people' => sharers.size })
        end

        ip_sharers = @collusion.ip_sharers(@person.id, @claim.ip)
        if ip_sharers.size >= 2
          add(code: :shared_ip, category: :collusion, weight: 12.0,
              message: "与其他 #{ip_sharers.size} 名无关联认领人共用同一出口 IP",
              evidence: { 'other_people' => ip_sharers.size })
        end
      end

      repeat = @collusion.repeat_co_claimers(@person.id, 2)
      if repeat.any?
        add(code: :repeat_co_claimers, category: :collusion, weight: 22.0,
            message: "与 #{repeat.size} 名人员反复共同认领多辆车,疑似同一中介网络",
            evidence: { 'co_claimers' => repeat.size })
      end
    end
  end
end
