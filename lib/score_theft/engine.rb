# frozen_string_literal: true

module ScoreTheft
  # 批次级风险评估引擎:载入数据、自检、逐条研判、汇总输出。
  # 面向管理层/审核岗的入口。
  class Engine
    attr_reader :dataset, :policy, :analyzer

    def initialize(dataset, policy: Policy.new)
      @dataset = dataset
      @policy = policy
      @analyzer = Analyzer.new(dataset, policy: policy)
    end

    def self.from_file(path, policy: Policy.new)
      new(Dataset.from_file(path), policy: policy)
    end

    # 数据完整性自检。脏数据必须显式报出,不能静默参与判断。
    def validate!
      @dataset.validate!
    end

    # 对全部认领逐条研判。
    def assess_all
      @dataset.claims.map do |claim|
        decision = @analyzer.assess(claim)
        { claim: claim, decision: decision }
      end
    end

    # 汇总统计 + 明细。
    def run
      results = assess_all
      {
        'generated_at' => Time.now.utc.iso8601,
        'engine_version' => VERSION,
        'policy' => policy.to_h,
        'claim_count' => results.size,
        'summary' => summarize(results),
        'results' => results.map { |r| result_hash(r[:claim], r[:decision]) }
      }
    end

    private

    def summarize(results)
      by_level = Hash.new(0)
      results.each { |r| by_level[r[:decision].level] += 1 }
      {
        'clear' => by_level[:clear],
        'review' => by_level[:review],
        'reject' => by_level[:reject],
        'evidence_insufficient' => by_level[:evidence_insufficient],
        'human_review_required' => results.count { |r| r[:decision].requires_human? },
        'auto_accepted' => results.count { |r| r[:decision].auto_accept? }
      }
    end

    def result_hash(claim, decision)
      h = {
        'claim_id' => claim.id,
        'violation_id' => claim.violation_id,
        'person_id' => claim.person_id,
        'vehicle_id' => claim.vehicle_id,
        'violation_at' => Util.format_time(claim.violation_at),
        'claim_at' => Util.format_time(claim.claim_at),
        'points' => claim.points,
        'level' => decision.level.to_s,
        'level_label' => decision.label,
        'auto_accept' => decision.auto_accept?,
        'requires_human_review' => decision.requires_human?,
        'adverse_finding' => decision.adverse_finding?,
        'reasons' => decision.reasons
      }

      signals = decision.signals
      if signals
        h['relation'] = {
          'level' => signals.relation.level.to_s,
          'kind' => signals.relation.kind.to_s,
          'source' => signals.relation.source.to_s,
          'evidence' => signals.relation.evidence
        }
        h['total_score'] = signals.total_score
        h['category_scores'] = signals.category_scores.transform_keys(&:to_s)
        h['substantive_categories'] = signals.substantive_categories
        h['hard_signal'] = signals.hard?
        h['findings'] = signals.findings.map(&:to_h)
        h['benign_notes'] = signals.benign_notes
        h['window'] = {
          'start' => Util.format_time(signals.window_start),
          'end' => Util.format_time(signals.anchor),
          'unrelated_claims' => signals.unrelated_claims.size,
          'distinct_unrelated_vehicles' => signals.distinct_unrelated_vehicle_ids.size
        }
      end

      h
    end
  end
end
