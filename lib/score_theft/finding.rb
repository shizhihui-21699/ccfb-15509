# frozen_string_literal: true

module ScoreTheft
  # 一条命中的信号。weight 是它对该类别风险分的贡献(0-100),
  # message 是给复核人员看的、必须能直接读懂的解释。
  class Finding
    attr_reader :code, :category, :weight, :message, :evidence

    def initialize(code:, category:, weight:, message:, evidence: {})
      @code = code
      @category = category
      @weight = weight.to_f
      @message = message
      @evidence = evidence
    end

    def active?
      weight.positive?
    end

    def to_h
      {
        'code' => code.to_s,
        'category' => category.to_s,
        'category_label' => CATEGORY_LABELS.fetch(category, category.to_s),
        'weight' => weight.round(2),
        'message' => message,
        'evidence' => evidence
      }
    end
  end
end
