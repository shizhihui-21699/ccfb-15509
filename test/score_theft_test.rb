# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/score_theft'

# 测试重点不是“能抓到多少”,而是:
#   1. 正常场景(夫妻共用、家人借车、照片模糊、代驾)绝不误判;
#   2. 真实欺诈(分贩子、时空矛盾、团伙)能被识别;
#   3. “拒绝”档必须有硬信号或三个实质类别,单一信号不能定罪;
#   4. 每一项结论都附带可解释的依据。
class ScoreTheftTest < Minitest::Test
  include ScoreTheft

  # 构造最小数据集并跑分析,返回 {claim_id => Decision}
  def assess(people:, vehicles:, claims:, relationships: [], policy: Policy.new)
    ds = Dataset.from_hash(
      people: people, vehicles: vehicles,
      relationships: relationships, claims: claims
    )
    analyzer = Analyzer.new(ds, policy: policy)
    ds.claims.each_with_object({}) do |c, h|
      h[c.id] = analyzer.assess(c)
    end
  end

  def person(id, household: nil, created: nil)
    { id: id, name: id, household_id: household, account_created_at: created }
  end

  def vehicle(id, owners: [], kind: 'private')
    { id: id, plate: id, kind: kind, owners: owners }
  end

  def claim(id, person_id:, vehicle_id:, at:, points: 3, quality: 'blurry',
            face_visible: nil, face_score: nil, declared: nil, device: nil,
            ip: nil, claimed_at: nil, lat: nil, lon: nil, loc_name: nil)
    photo = { quality: quality }
    photo[:face_visible] = face_visible unless face_visible.nil?
    photo[:face_match_score] = face_score unless face_score.nil?
    h = {
      id: id, person_id: person_id, vehicle_id: vehicle_id,
      violation_at: at, claim_at: claimed_at || at,
      points: points, photo: photo,
      declared_relationship: declared, device_id: device, ip: ip
    }
    h[:location] = { name: loc_name, lat: lat, lon: lon } if lat && lon
    h
  end

  # ---- 误判防线:正常场景必须通过 --------------------------------

  def test_owner_is_clear_even_with_blurry_photo
    decisions = assess(
      people: [person('P1')],
      vehicles: [vehicle('V1', owners: [{ person_id: 'P1', since: '2015-01-01' }])],
      claims: [claim('C1', person_id: 'P1', vehicle_id: 'V1',
                     at: '2020-06-01T10:00:00+08:00', quality: 'blurry')]
    )
    assert_equal :clear, decisions['C1'].level
    assert decisions['C1'].auto_accept?
  end

  def test_spouse_sharing_one_car_is_clear
    decisions = assess(
      people: [person('P1', household: 'H1'), person('P2', household: 'H1')],
      vehicles: [vehicle('V1', owners: [{ person_id: 'P1', since: '2015-01-01' }])],
      claims: [
        claim('C1', person_id: 'P2', vehicle_id: 'V1',
              at: '2020-06-01T10:00:00+08:00', points: 3),
        claim('C2', person_id: 'P2', vehicle_id: 'V1',
              at: '2020-07-01T10:00:00+08:00', points: 6),
        claim('C3', person_id: 'P1', vehicle_id: 'V1',
              at: '2020-08-01T10:00:00+08:00', points: 2)
      ]
    )
    decisions.each_value { |d| assert_equal :clear, d.level }
  end

  def test_blurry_photo_with_unverified_friend_is_evidence_insufficient_not_reject
    decisions = assess(
      people: [person('P1'), person('P2')],
      vehicles: [vehicle('V1', owners: [{ person_id: 'P1' }])],
      claims: [claim('C1', person_id: 'P2', vehicle_id: 'V1',
                     at: '2020-06-01T10:00:00+08:00',
                     quality: 'blurry', declared: '朋友')]
    )
    d = decisions['C1']
    assert_equal :evidence_insufficient, d.level
    refute d.adverse_finding?, '证据不足绝不能是 adverse_finding'
  end

  def test_driver_for_rental_cars_is_clear
    decisions = assess(
      people: [person('P1')],
      vehicles: [vehicle('R1', kind: 'rental'), vehicle('R2', kind: 'rental'),
                 vehicle('R3', kind: 'rental'), vehicle('R4', kind: 'rental')],
      claims: (1..4).map do |i|
        claim("C#{i}", person_id: 'P1', vehicle_id: "R#{i}",
              at: "2020-06-#{format('%02d', i * 3)}T10:00:00+08:00")
      end
    )
    decisions.each_value { |d| assert_equal :clear, d.level }
  end

  # ---- 单一信号不能定罪 ------------------------------------------

  def test_single_duplicate_claim_does_not_reject_either_party
    # 同一条违法被两人认领:只能证明有人撒谎,不能证明是谁。
    decisions = assess(
      people: [person('P1'), person('P2')],
      vehicles: [vehicle('V1', owners: [{ person_id: 'P9' }])],
      claims: [
        claim('C1', person_id: 'P1', vehicle_id: 'V1',
              at: '2020-06-01T10:00:00+08:00'),
        claim('C2', person_id: 'P2', vehicle_id: 'V1',
              at: '2020-06-01T10:00:00+08:00')
      ]
    )
    # 双方都应转人工,但绝不自动拒绝其中任何一方。
    assert_equal :review, decisions['C1'].level
    assert_equal :review, decisions['C2'].level
    refute decisions['C1'].adverse_finding?
    refute decisions['C2'].adverse_finding?
  end

  def test_three_unrelated_vehicles_alone_is_not_reject
    # 3 辆陌生车、全模糊照片:不到拒绝档,应转人工。
    claims = (1..3).map do |i|
      claim("C#{i}", person_id: 'P1', vehicle_id: "V#{i}",
            at: "2020-0#{i}-01T10:00:00+08:00")
    end
    decisions = assess(
      people: [person('P1')],
      vehicles: (1..3).map { |i| vehicle("V#{i}", owners: [{ person_id: "X#{i}" }]) },
      claims: claims
    )
    decisions.each_value do |d|
      refute_equal :reject, d.level, '3 辆陌生车不足以自动拒绝'
    end
  end

  # ---- 真实欺诈必须识别 ------------------------------------------

  def test_professional_score_seller_is_rejected
    claims = (1..8).map do |i|
      claim("C#{i}", person_id: 'P1', vehicle_id: "V#{i}",
            at: "2020-#{format('%02d', i + 1)}-01T10:00:00+08:00",
            points: 6, device: 'DEV-X', ip: '10.0.0.1')
    end
    decisions = assess(
      people: [person('P1')],
      vehicles: (1..8).map { |i| vehicle("V#{i}", owners: [{ person_id: "X#{i}" }]) },
      claims: claims
    )
    decisions.each_value do |d|
      assert_equal :reject, d.level, "分贩子的每一次认领都应转复核,而不仅是最后一次"
      assert d.adverse_finding?
      assert d.requires_human?, '拒绝档必须要求人工复核'
    end
  end

  def test_early_claim_of_score_seller_is_also_caught
    # 关键回归:分贩子的第一次认领也要能识别,不能只看“案发之前”的行为。
    claims = (1..8).map do |i|
      claim("C#{i}", person_id: 'P1', vehicle_id: "V#{i}",
            at: "2020-#{format('%02d', i + 1)}-01T10:00:00+08:00", points: 6)
    end
    decisions = assess(
      people: [person('P1')],
      vehicles: (1..8).map { |i| vehicle("V#{i}", owners: [{ person_id: "X#{i}" }]) },
      claims: claims
    )
    assert_equal :reject, decisions['C1'].level, '第 1 次认领也必须能被识别'
  end

  def test_impossible_travel_is_rejected
    decisions = assess(
      people: [person('P1')],
      vehicles: [vehicle('V1', owners: [{ person_id: 'X' }]),
                 vehicle('V2', owners: [{ person_id: 'Y' }])],
      claims: [
        claim('C1', person_id: 'P1', vehicle_id: 'V1',
              at: '2020-06-01T09:00:00+08:00', points: 12,
              lat: 31.2304, lon: 121.4737, loc_name: '上海'),
        claim('C2', person_id: 'P1', vehicle_id: 'V2',
              at: '2020-06-01T10:30:00+08:00', points: 12,
              lat: 39.9042, lon: 116.4074, loc_name: '北京')
      ]
    )
    assert_equal :reject, decisions['C1'].level
    assert_equal :reject, decisions['C2'].level
  end

  def test_clear_face_mismatch_supports_reject
    decisions = assess(
      people: [person('P1')],
      vehicles: [vehicle('V1', owners: [{ person_id: 'X' }])],
      claims: [claim('C1', person_id: 'P1', vehicle_id: 'V1',
                     at: '2020-06-01T10:00:00+08:00', points: 6,
                     quality: 'clear', face_visible: true, face_score: 0.12)]
    )
    # 清晰照片 + 明显不符是硬信号;但只有 2 个实质类别(关联+照片),
    # 未达 3 个,硬信号成立即可拒绝。
    assert_equal :reject, decisions['C1'].level
  end

  def test_blurry_photo_never_becomes_mismatch
    # 同样的“无关联”情形,但照片模糊 → 不得因照片糊而升为拒绝。
    decisions = assess(
      people: [person('P1')],
      vehicles: [vehicle('V1', owners: [{ person_id: 'X' }])],
      claims: [claim('C1', person_id: 'P1', vehicle_id: 'V1',
                     at: '2020-06-01T10:00:00+08:00', points: 6,
                     quality: 'blurry')]
    )
    refute_equal :reject, decisions['C1'].level
  end

  # ---- 关联核验 ---------------------------------------------------

  def test_verified_relationship_record_counts_as_associated
    decisions = assess(
      people: [person('P1'), person('P2')],
      vehicles: [vehicle('V1', owners: [{ person_id: 'P2' }])],
      relationships: [{ person_id: 'P1', vehicle_id: 'V1', type: 'friend',
                        verified: true, since: '2020-01-01',
                        evidence: '借用协议已核验' }],
      claims: [claim('C1', person_id: 'P1', vehicle_id: 'V1',
                     at: '2020-06-01T10:00:00+08:00')]
    )
    assert_equal :clear, decisions['C1'].level
    assert decisions['C1'].signals.relation.verified?
  end

  def test_relationship_outside_validity_period_does_not_count
    # 关系备案在违法发生前已到期,不应被认作有关联。
    decisions = assess(
      people: [person('P1'), person('P2')],
      vehicles: [vehicle('V1', owners: [{ person_id: 'P2' }])],
      relationships: [{ person_id: 'P1', vehicle_id: 'V1', type: 'rental_contract',
                        verified: true, since: '2019-01-01', until: '2019-12-31' }],
      claims: [claim('C1', person_id: 'P1', vehicle_id: 'V1',
                     at: '2020-06-01T10:00:00+08:00')]
    )
    refute decisions['C1'].signals.relation.verified?
  end

  # ---- 可解释性 & 输出 --------------------------------------------

  def test_every_finding_has_human_readable_message
    claims = (1..8).map do |i|
      claim("C#{i}", person_id: 'P1', vehicle_id: "V#{i}",
            at: "2020-#{format('%02d', i + 1)}-01T10:00:00+08:00", points: 6)
    end
    ds = Dataset.from_hash(
      people: [person('P1')],
      vehicles: (1..8).map { |i| vehicle("V#{i}", owners: [{ person_id: "X#{i}" }]) },
      claims: claims
    )
    engine = Engine.new(ds)
    result = engine.run
    result['results'].each do |r|
      Array(r['findings']).each do |f|
        refute_empty f['message'].to_s, "finding #{f['code']} 缺少说明"
        assert f.key?('weight')
      end
    end
  end

  def test_report_renders_without_error
    ds = Dataset.from_file(File.expand_path('../data/sample_claims.json', __dir__))
    result = Engine.new(ds).run
    text = Report.render(result)
    assert_includes text, '违章认领研判报告'
    assert_includes text, '汇总'
    assert result['summary']['reject'].positive?, '样例应包含疑似顶替案例'
    assert result['summary']['clear'].positive?, '样例应包含正常通过案例'
  end

  def test_policy_overrides_are_honored
    # 把拒绝门槛调到 100,则即使分贩子也最多到 review。
    strict = Policy.new(decision_high: 101)
    claims = (1..8).map do |i|
      claim("C#{i}", person_id: 'P1', vehicle_id: "V#{i}",
            at: "2020-#{format('%02d', i + 1)}-01T10:00:00+08:00", points: 6)
    end
    decisions = assess(
      people: [person('P1')],
      vehicles: (1..8).map { |i| vehicle("V#{i}", owners: [{ person_id: "X#{i}" }]) },
      claims: claims, policy: strict
    )
    decisions.each_value { |d| refute_equal :reject, d.level }
  end

  def test_validate_catches_dangling_references
    ds = Dataset.from_hash(
      people: [person('P1')],
      vehicles: [],
      claims: [claim('C1', person_id: 'P1', vehicle_id: 'MISSING',
                     at: '2020-06-01T10:00:00+08:00')]
    )
    errors = ds.validate!
    assert errors.any? { |e| e.include?('MISSING') }
  end
end
