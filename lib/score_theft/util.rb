# frozen_string_literal: true

module ScoreTheft
  module Util
    module_function

    # JSON 解析出来的哈希键是字符串,深递归转成符号,方便模型读取。
    def deep_symbolize(obj)
      case obj
      when Hash
        obj.each_with_object({}) { |(k, v), h| h[k.to_sym] = deep_symbolize(v) }
      when Array
        obj.map { |v| deep_symbolize(v) }
      else
        obj
      end
    end

    EARTH_RADIUS_KM = 6371.0088

    # 两点间球面距离(公里)。用于识别“同一人同一时段出现在相距数百公里的两地”。
    def haversine_km(lat1, lon1, lat2, lon2)
      rad = Math::PI / 180.0
      dlat = (lat2 - lat1) * rad
      dlon = (lon2 - lon1) * rad
      a = Math.sin(dlat / 2)**2 +
          Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * Math.sin(dlon / 2)**2
      2 * EARTH_RADIUS_KM * Math.asin(Math.sqrt(a))
    end

    # 概率并集:多个独立信号中至少一个成立的概率。
    # 权重越高、信号越多,得分越高,但单类封顶由调用方控制。
    def noisy_or(weights)
      return 0.0 if weights.empty?

      prod = weights.reduce(1.0) do |acc, w|
        clamped = [[w.to_f, 0.0].max, 100.0].min
        acc * (1.0 - clamped / 100.0)
      end
      (1.0 - prod) * 100.0
    end

    def days_between(from, to)
      return 0.0 if from.nil? || to.nil?

      (to - from) / 86_400.0
    end

    def hours_between(from, to)
      return 0.0 if from.nil? || to.nil?

      (to - from) / 3_600.0
    end

    def format_time(t)
      return '-' if t.nil?

      t.strftime('%Y-%m-%d %H:%M %z')
    end
  end
end
