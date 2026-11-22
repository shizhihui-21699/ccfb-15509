# frozen_string_literal: true

module ScoreTheft
  # 车辆登记关系(所有人 / 登记使用人),带生效区间。
  Ownership = Struct.new(:person_id, :since, :until)

  # 违法发生地,用于“同一人不可能同时出现在两地”的判定。
  Location = Struct.new(:name, :lat, :lon)

  # 认领人与车辆之间的关联判定结果。
  #   level  : :verified 已核验 / :weak 仅声明未核验 / :none 无任何关联
  #   kind   : :owner / :registered_driver / :family / :friend / :rental / ...
  #   source : :registry(登记库) / :declared_verified(声明已核验) /
  #            :declared_unverified / :none
  Relation = Struct.new(:level, :kind, :source, :evidence) do
    def verified?
      level == :verified
    end

    def weak?
      level == :weak
    end

    def none?
      level == :none
    end
  end

  NO_RELATION = Relation.new(:none, :unknown, :none, nil)

  class Person
    attr_reader :id, :name, :license_no, :household_id, :account_created_at, :meta

    def initialize(attrs)
      @id = attrs[:id]
      @name = attrs[:name] || attrs[:id]
      @license_no = attrs[:license_no]
      @household_id = attrs[:household_id]
      @account_created_at = TimeParse.call(attrs[:account_created_at])
      @meta = attrs[:meta] || {}
    end

    def to_s
      name.to_s
    end
  end

  class Vehicle
    attr_reader :id, :plate, :kind, :owners, :registered_drivers, :meta

    def initialize(attrs)
      @id = attrs[:id]
      @plate = attrs[:plate] || attrs[:id]
      @kind = (attrs[:kind] || 'private').to_s
      @owners = parse_entries(attrs[:owners])
      @registered_drivers = parse_entries(attrs[:registered_drivers])
      @meta = attrs[:meta] || {}
    end

    def rental?
      kind == 'rental'
    end

    def fleet?
      kind == 'fleet'
    end

    # 运营车辆(租车公司、单位车队):陌生人认领本就常见,关系信号应更谨慎。
    def company?
      rental? || fleet?
    end

    def to_s
      plate.to_s
    end

    private

    def parse_entries(list)
      Array(list).map do |e|
        e = { person_id: e } if e.is_a?(String)
        Ownership.new(
          e[:person_id],
          TimeParse.call(e[:since]),
          TimeParse.call(e[:until])
        )
      end
    end
  end

  class Relationship
    attr_reader :person_id, :vehicle_id, :type, :verified, :since, :until, :evidence, :meta

    def initialize(attrs)
      @person_id = attrs[:person_id]
      @vehicle_id = attrs[:vehicle_id]
      @type = (attrs[:type] || 'friend').to_sym
      @verified = attrs[:verified] == true
      @since = TimeParse.call(attrs[:since])
      @until_at = TimeParse.call(attrs[:until])
      @evidence = attrs[:evidence]
      @meta = attrs[:meta] || {}
    end

    attr_reader :until_at

    def covers?(at)
      return false if at.nil?

      (since.nil? || since <= at) && (until_at.nil? || at <= until_at)
    end
  end

  # 违法照片证据。关键区分:照片“看不清”不等于“不是他开的”。
  class PhotoEvidence
    attr_reader :quality, :face_visible, :face_match_score, :meta

    def initialize(attrs = nil)
      attrs ||= {}
      @quality = (attrs[:quality] || 'none').to_s
      @face_visible = attrs[:face_visible]
      @face_match_score = attrs[:face_match_score]
      @meta = attrs[:meta] || {}
    end

    def clear?
      quality == 'clear'
    end

    # 只有照片清晰且能辨认出面部,才具备做身份比对的前提条件。
    def readable?
      clear? && face_visible == true
    end

    def unreadable?
      !readable?
    end

    def reason
      return '未提供违法照片' if quality == 'none'
      return '照片模糊' if quality == 'blurry'
      return '照片清晰但无法辨认驾驶人面部' if clear? && face_visible != true
      return '照片中未定位到人脸' if face_visible == false

      '照片质量不足以辨认驾驶人'
    end
  end

  class Claim
    attr_reader :id, :violation_id, :person_id, :vehicle_id, :violation_at, :claim_at,
                :photo, :declared_relationship, :evidence, :channel, :device_id,
                :points, :fine, :location, :ip, :meta

    def initialize(attrs)
      @id = attrs[:id]
      @violation_id = attrs[:violation_id] || attrs[:id]
      @person_id = attrs[:person_id]
      @vehicle_id = attrs[:vehicle_id]
      @violation_at = TimeParse.call(attrs[:violation_at])
      @claim_at = TimeParse.call(attrs[:claim_at]) || @violation_at
      @photo = PhotoEvidence.new(attrs[:photo])
      @declared_relationship = attrs[:declared_relationship] && attrs[:declared_relationship].to_s
      @evidence = Array(attrs[:evidence]).map(&:to_s)
      @channel = (attrs[:channel] || 'app').to_s
      @device_id = attrs[:device_id] && attrs[:device_id].to_s
      @points = (attrs[:points] || 0).to_i
      @fine = (attrs[:fine] || 0).to_i
      loc = attrs[:location]
      @location = loc ? Location.new(loc[:name], loc[:lat], loc[:lon]) : nil
      @ip = attrs[:ip]
      @meta = attrs[:meta] || {}
    end

    def geo?
      !location.nil? && !location.lat.nil? && !location.lon.nil?
    end

    def to_s
      id.to_s
    end
  end
end
