# frozen_string_literal: true

module ScoreTheft
  # 判定「认领人与车辆之间到底有没有真实关联」。
  #
  # 分级标准:
  #   :verified —— 有官方/可核验来源:车辆登记为所有人、登记使用人、
  #                同户成员,或存在已核验的关系备案(借用协议、租赁合同)。
  #   :weak     —— 当事人自称的亲友关系,或系统里有未核验的备案。
  #   :none     —— 查无任何关联。
  #
  # 关键取向:只有 :none 才计入「无关联车辆」数量统计。
  # 未核验的自称关系绝不直接当成撒谎——先记为 :weak,单独低权重处理。
  class RelationResolver
    def initialize(dataset)
      @dataset = dataset
      @memo = {}
    end

    def resolve(claim)
      @memo[claim.id] ||= compute(claim)
    end

    private

    def compute(claim)
      person = @dataset.person(claim.person_id)
      vehicle = @dataset.vehicle(claim.vehicle_id)
      return NO_RELATION if person.nil? || vehicle.nil?

      at = claim.violation_at

      # 1) 车辆登记关系:所有人 / 登记使用人(在违法发生时有效)
      owner = find_entry(vehicle.owners, person.id, at)
      if owner
        return Relation.new(:verified, :owner, :registry,
                            "登记为车牌 #{vehicle.plate} 的所有人" \
                            "#{period_note(owner)}")
      end

      driver = find_entry(vehicle.registered_drivers, person.id, at)
      if driver
        return Relation.new(:verified, :registered_driver, :registry,
                            "登记为车牌 #{vehicle.plate} 的登记使用人" \
                            "#{period_note(driver)}")
      end

      # 2) 同户成员:户籍/家庭关系是真实且稳定的,视为已核验的家人用车。
      household = household_owner(vehicle, person, at)
      if household
        return Relation.new(:verified, :family, :registry,
                            "与车主 #{household.name} 同户(户号 #{person.household_id})," \
                            '属家庭共用车辆')
      end

      # 3) 关系备案:优先采用已核验的,覆盖违法发生时间的。
      records = @dataset.relationships_for(person.id, vehicle.id)
                     .select { |r| r.covers?(at) }
      verified = records.find(&:verified)
      if verified
        return Relation.new(:verified, verified.type, :declared_verified,
                            "关系备案已核验:#{kind_label(verified.type)}" \
                            "#{evidence_note(verified)}")
      end

      # 4) 未核验的关系(含当事人自行声明的亲友关系)
      unless records.empty?
        return Relation.new(:weak, records.first.type, :declared_unverified,
                            "仅有无核验记录的关系声明:#{kind_label(records.first.type)}")
      end

      if claim.declared_relationship
        return Relation.new(:weak, claim.declared_relationship.to_sym,
                            :declared_unverified,
                            "仅在认领时声明关系:#{claim.declared_relationship}")
      end

      Relation.new(:none, :unknown, :none, '系统内查无该人与该车的任何关联')
    end

    def find_entry(entries, person_id, at)
      entries.find do |e|
        next false unless e.person_id == person_id
        next false unless at.nil? || e.since.nil? || e.since <= at

        e.until.nil? || at.nil? || at <= e.until
      end
    end

    # 同户成员中,有人在违法发生时是该车登记所有人。
    def household_owner(vehicle, person, at)
      return nil if person.household_id.nil?

      members = @dataset.household_members(person.household_id)
                   .reject { |p| p.id == person.id }
      members.find do |member|
        vehicle.owners.any? do |e|
          next false unless e.person_id == member.id
          next false unless at.nil? || e.since.nil? || e.since <= at

          e.until.nil? || at.nil? || at <= e.until
        end
      end
    end

    def period_note(entry)
      bits = []
      bits << "登记自 #{entry.since.strftime('%Y-%m-%d')}" if entry.since
      bits << "至 #{entry.until.strftime('%Y-%m-%d')}" if entry.until
      bits.empty? ? '' : "(#{bits.join(',')})"
    end

    def evidence_note(rel)
      rel.evidence ? "(#{rel.evidence})" : ''
    end

    def kind_label(kind)
      {
        family: '家庭成员', friend: '朋友', colleague: '同事',
        rental_contract: '租赁合同', work_order: '单位派车单',
        spouse: '配偶'
      }.fetch(kind, kind.to_s)
    end
  end
end
