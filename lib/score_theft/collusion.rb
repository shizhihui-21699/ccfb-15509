# frozen_string_literal: true

module ScoreTheft
  # 团伙/中介特征识别。分车分贩子的典型形态:
  #   - 一辆车一年内被一群互不相关的人轮流认领;
  #   - 同一个违法记录被两个人同时认领(必有一假);
  #   - 一群互不相关的人用同一台设备/同一出口提交认领;
  #   - 同一个人反复出现在多辆车的陌生认领里,形成“中介”节点。
  #
  # 所有统计都只针对 :none(查无关联)的认领,家人、同户、已核验借用
  # 一律排除,避免把家庭共用车辆误当成团伙。
  class CollusionIndex
    attr_reader :unrelated_claims

    def initialize(dataset, relations, policy)
      @dataset = dataset
      @policy = policy
      @relations = relations
      @unrelated_claims = dataset.claims.select do |c|
        rel = @relations[c.id]
        rel && rel.none?
      end

      build
    end

    # 该车有多少个互不相关的认领人。
    def vehicle_claimer_count(vehicle_id)
      @vehicle_claimers.fetch(vehicle_id, Set.new).size
    end

    def vehicle_claimers(vehicle_id)
      @vehicle_claimers.fetch(vehicle_id, Set.new)
    end

    # 同一违法行为被多人认领:返回认领人集合。
    def duplicate_claimers(claim)
      key = [claim.vehicle_id, claim.violation_at]
      @violation_claimers.fetch(key, Set.new)
    end

    # 与本人共用过提交设备的其他无关联认领人。
    def device_sharers(person_id, device_id)
      return [] if device_id.nil?

      (@device_owners[device_id] || Set.new) - [person_id]
    end

    # 与本人共用过 IP 的其他无关联认领人。
    def ip_sharers(person_id, ip)
      return [] if ip.nil?

      (@ip_owners[ip] || Set.new) - [person_id]
    end

    # 与本人共同为 >= min_shared 辆「同一辆车」做过无关联认领的其他人员,
    # 即疑似同一中介网络里的同伙。
    def repeat_co_claimers(person_id, min_shared = 2)
      bench = @person_vehicles.fetch(person_id, Set.new)
      counts = Hash.new(0)
      bench.each do |vehicle_id|
        (@vehicle_people[vehicle_id] || Set.new).each do |other|
          counts[other] += 1 unless other == person_id
        end
      end
      counts.select { |_, n| n >= min_shared }.keys
    end

    private

    def build
      @vehicle_claimers = Hash.new { |h, k| h[k] = Set.new }
      @violation_claimers = Hash.new { |h, k| h[k] = Set.new }
      @device_owners = Hash.new { |h, k| h[k] = Set.new }
      @ip_owners = Hash.new { |h, k| h[k] = Set.new }
      @person_vehicles = Hash.new { |h, k| h[k] = Set.new }
      @vehicle_people = Hash.new { |h, k| h[k] = Set.new }

      @unrelated_claims.each do |c|
        @vehicle_claimers[c.vehicle_id] << c.person_id
        @violation_claimers[[c.vehicle_id, c.violation_at]] << c.person_id
        @device_owners[c.device_id] << c.person_id if c.device_id
        @ip_owners[c.ip] << c.person_id if c.ip
        @person_vehicles[c.person_id] << c.vehicle_id
        @vehicle_people[c.vehicle_id] << c.person_id
      end
    end
  end
end
