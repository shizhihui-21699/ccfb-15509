# frozen_string_literal: true

module ScoreTheft
  # 判定阈值与口径。全部可被策略文件覆盖,便于按地区/警种调整,
  # 而不必改代码。
  #
  # 注意:调整阈值属于执法政策决定,应留档并说明依据。
  class Policy
    ATTRS = %i[
      window_days
      claim_count_medium claim_count_high
      annual_points_medium annual_points_high
      extreme_vehicle_count
      household_point_cap
      short_window_days short_window_count
      burst_hours burst_count
      late_claim_days
      face_mismatch_strong face_mismatch_partial
      new_account_days
      vehicle_claimers_medium vehicle_claimers_high
      decision_medium decision_high
      reject_min_substantive_categories
      require_human_confirmation
    ].freeze

    DEFAULTS = {
      # 统计窗口:以每次违法发生日为锚点,向前回溯一年。
      window_days: 365,

      # 一年内认领「无关联车辆」的辆数,中/高档。
      claim_count_medium: 3,
      claim_count_high: 6,

      # 一年内为「无关联车辆」累计背的分数,中/高档。
      # 一个记分周期满分 12 分,短期内背到 20 分以上已明显异常。
      annual_points_medium: 20,
      annual_points_high: 42,

      # 一年内为多少辆「互不相关的陌生私家车」认领,直接构成硬信号。
      # 取 8:家庭共享车辆(bounded by household)、租车/代驾(按运营车辆
      # 折半且不计入此项)、以及少数真正的朋友借车,都远达不到这个量级。
      extreme_vehicle_count: 8,

      # 同一家庭成员替「同户名下、但自己非登记人」的多辆车集中背分的容量。
      # 取 24(两个记分周期):夫妻共用一车、一人担大部分分是常态,不该触发。
      household_point_cap: 24,

      # 短期集中认领:short_window_days 天内认领次数达到 short_window_count。
      short_window_days: 7,
      short_window_count: 3,

      # 更短时间内的批量操作(疑似中介批量“处理”)。
      burst_hours: 48,
      burst_count: 3,

      # 违法发生很久之后才认领,常见于中介集中处理积压违章。
      late_claim_days: 30,

      # 人脸比对相似度(0-1)。低于 strong 视为明显不符;
      # 介于 partial 与 strong 之间视为存疑但不足以单独定性。
      face_mismatch_strong: 0.35,
      face_mismatch_partial: 0.55,

      # 账号在首次认领前不久才注册。
      new_account_days: 30,

      # 同一车辆被多少个「互不相关」的人认领过,中/高档。
      vehicle_claimers_medium: 3,
      vehicle_claimers_high: 5,

      # 综合风险分决策门槛。
      decision_medium: 35,
      decision_high: 60,

      # 判定「拒绝」至少需要几个实质类别同时成立。
      # 实质类别 = relationship / volume / photo / collusion;
      # 仅靠 temporal+behavioral 不能拒绝,避免误伤。
      reject_min_substantive_categories: 2,

      # 是否强制要求人工复核(生产环境应保持 true)。
      require_human_confirmation: true
    }.freeze

    ATTRS.each { |attr| attr_reader attr }

    def initialize(overrides = {})
      merged = DEFAULTS.merge(Util.deep_symbolize(overrides))
      ATTRS.each { |attr| instance_variable_set("@#{attr}", merged.fetch(attr)) }
    end

    def self.from_file(path)
      new(JSON.parse(File.read(path)))
    end

    def self.from_hash(hash)
      new(hash)
    end

    def to_h
      ATTRS.each_with_object({}) { |attr, h| h[attr] = public_send(attr) }
    end
  end
end
