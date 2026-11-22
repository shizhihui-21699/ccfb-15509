# frozen_string_literal: true

module ScoreTheft
  # 内存中的数据集:人员、车辆、关系、认领记录。
  # 可从 JSON 文件或 Hash 载入,并建立常用索引。
  class Dataset
    attr_reader :people, :vehicles, :relationships, :claims

    def self.from_file(path)
      raw = JSON.parse(File.read(path))
      from_hash(Util.deep_symbolize(raw))
    end

    def self.from_hash(hash)
      h = Util.deep_symbolize(hash)
      new(
        people: Array(h[:people]).map { |a| Person.new(a) },
        vehicles: Array(h[:vehicles]).map { |a| Vehicle.new(a) },
        relationships: Array(h[:relationships]).map { |a| Relationship.new(a) },
        claims: Array(h[:claims]).map { |a| Claim.new(a) }
      )
    end

    def initialize(people: [], vehicles: [], relationships: [], claims: [])
      @people = people
      @vehicles = vehicles
      @relationships = relationships
      @claims = claims

      @people_by_id = people.each_with_object({}) { |p, h| h[p.id] = p }
      @vehicles_by_id = vehicles.each_with_object({}) { |v, h| h[v.id] = v }
      @claims_by_person = claims.group_by(&:person_id)
      @claims_by_vehicle = claims.group_by(&:vehicle_id)
      @relationships_by_pair = relationships.group_by { |r| [r.person_id, r.vehicle_id] }

      @claims_by_person.each_value { |list| list.sort_by! { |c| c.claim_at || Time.at(0) } }
      @claims.sort_by! { |c| c.claim_at || Time.at(0) }
    end

    def person(id)
      @people_by_id[id]
    end

    def vehicle(id)
      @vehicles_by_id[id]
    end

    def claims_for_person(id)
      @claims_by_person[id] || []
    end

    def claims_for_vehicle(id)
      @claims_by_vehicle[id] || []
    end

    def relationships_for(person_id, vehicle_id)
      @relationships_by_pair[[person_id, vehicle_id]] || []
    end

    def household_members(household_id)
      return [] if household_id.nil?

      @people.select { |p| p.household_id == household_id }
    end

    # 数据完整性自检。用于在分析前尽早暴露脏数据,而不是让它悄悄影响结论。
    def validate!
      errors = []

      claims.each do |c|
        errors << "认领 #{c.id}: 缺少 person_id" if c.person_id.nil?
        errors << "认领 #{c.id}: 缺少 vehicle_id" if c.vehicle_id.nil?
        errors << "认领 #{c.id}: 人员 #{c.person_id} 不存在" if c.person_id && person(c.person_id).nil?
        errors << "认领 #{c.id}: 车辆 #{c.vehicle_id} 不存在" if c.vehicle_id && vehicle(c.vehicle_id).nil?
        errors << "认领 #{c.id}: 缺少违法时间" if c.violation_at.nil?
        errors << "认领 #{c.id}: 缺少认领时间" if c.claim_at.nil?
      end

      errors
    end
  end
end
