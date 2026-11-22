# frozen_string_literal: true

module ScoreTheft
  # 统一的宽松时间解析:接受 ISO8601 完整时间,也接受只有日期的
  # "2020-01-01"(如车辆登记日期、关系建立日期)。
  #
  # 只有日期时按 UTC 零点处理。对本引擎而言,登记类日期用于判断
  # “某次违法发生时该关系是否已经存在”,一天内的时区误差不影响结论。
  module TimeParse
    module_function

    DATE_ONLY = /\A(\d{4})-(\d{1,2})-(\d{1,2})\z/.freeze

    def call(value)
      return nil if value.nil?
      return value if value.is_a?(Time)

      s = value.to_s.strip
      return nil if s.empty?

      if (m = DATE_ONLY.match(s))
        Time.utc(m[1].to_i, m[2].to_i, m[3].to_i)
      else
        Time.iso8601(s)
      end
    end
  end
end
