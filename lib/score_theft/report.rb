# frozen_string_literal: true

module ScoreTheft
  # 把引擎输出渲染成便于人工复核的文本报告。
  # 原则:每条结论都要写清“依据什么、为什么”,让复核者能一眼看懂,
  # 也能直接拿去和当事人核对、听取申辩。
  module Report
    module_function

    def render(result)
      lines = []
      lines << '=' * 72
      lines << "违章认领研判报告(引擎 v#{result['engine_version']})"
      lines << "生成时间:#{result['generated_at']}"
      lines << '=' * 72
      lines << ''
      lines << summary_block(result)
      lines << ''
      result['results'].each { |r| lines << claim_block(r) }
      lines.join("\n")
    end

    def summary_block(result)
      s = result['summary']
      [
        '汇总',
        "  认领总数:#{result['claim_count']}",
        "  无异常(自动通过):#{s['clear']}",
        "  需人工核实:#{s['review']}",
        "  疑似顶替(转复核):#{s['reject']}",
        "  证据不足:#{s['evidence_insufficient']}",
        "  需人工介入合计:#{s['human_review_required']}"
      ].join("\n")
    end

    def claim_block(r)
      lines = []
      mark = {
        'clear' => '[通过]',
        'review' => '[核实]',
        'reject' => '[复核]',
        'evidence_insufficient' => '[证据不足]'
      }.fetch(r['level'], '[?]')

      lines << '-' * 72
      lines << "#{mark} 认领 #{r['claim_id']}(#{r['level_label']})"
      lines << "  人员:#{r['person_id']}  车辆:#{r['vehicle_id']}  扣分:#{r['points']}"
      lines << "  违法时间:#{r['violation_at']}  认领时间:#{r['claim_at']}"

      if (rel = r['relation'])
        lines << "  关联:#{rel['level']} / #{rel['kind']}(#{rel['evidence']})"
      end

      if r.key?('total_score')
        lines << "  综合风险分:#{r['total_score']}  实质类别:#{r['substantive_categories']}  硬信号:#{r['hard_signal'] ? '是' : '否'}"
        cats = r['category_scores'].reject { |_, v| v.to_f.zero? }
        unless cats.empty?
          lines << "  分项:#{cats.map { |k, v| "#{CATEGORY_LABELS.fetch(k.to_sym, k)}=#{v}" }.join(' ')}"
        end
        r['findings'].each { |f| lines << "    · [#{f['category_label']} +#{f['weight']}] #{f['message']}" }
        Array(r['benign_notes']).each { |n| lines << "    ~ #{n}" }
      end

      lines << "  结论:#{r['level_label']}#{r['requires_human_review'] ? '(需人工复核)' : ''}"
      if r['adverse_finding']
        lines << '  注意:本结论为不利认定,须经人工复核并保障当事人陈述申辩权后方可执行。'
      end
      lines.join("\n")
    end
  end
end
