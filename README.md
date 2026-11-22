# ScoreTheft —— 违章认领顶替扣分识别

用于交通管理违章处理平台。当有人认领一条违法记录时,判断「这个人到底是不是
真实驾驶人」,识别买卖驾照分中的**顶替认领**,同时严控误判。

纯 Ruby 实现,无外部依赖,可直接嵌入现有 Ruby/Rails 服务,也可独立跑批。

## 它解决的核心矛盾

借车给家人朋友再正常不过;违章照片也经常看不清驾驶人。**误判会让真正的
驾驶人被冤枉**,这比漏判几个分贩子更严重。所以整个引擎围绕三条硬约束设计:

1. **只对“指向欺诈的证据”加分。**
   照片模糊、人脸不可辨 → 记一条“证据不足”,**不产生任何不利推断**。
   把“没看到”当作“看到了相反的”,是冤案最主要的来源。

2. **单一信号永远不能定罪。**
   判“拒绝”必须同时满足:总分达高档 + 至少 2 个实质类别成立 +
   (命中硬信号 或 3 个实质类别同时成立)。模糊照片、单纯“数量多”
   都不可能独自把人判成顶替。

3. **“拒绝”只是转人工复核,不是处罚。**
   所有拒绝档都强制 `requires_human_review`,并提示须保障当事人陈述申辩权。
   引擎输出的是**研判结论和行动建议**,不是终局处罚。

## 六类信号

| 类别 | 看什么 | 典型正常场景如何豁免 |
|------|--------|----------------------|
| 关联核验 | 认领人和车有无真实关联(登记所有人/使用人/同户/已核验借用) | 家人、同户、已核验借用直接通过 |
| 数量异常 | 一年内替多少辆**陌生私家车**认领、背多少分 | 运营车辆(租车/车队)按半辆半分析算,不计入极端数量 |
| 时间异常 | 短期集中认领、批量提交、久拖才认领、时空矛盾 | 代驾/租车人短期开多辆租车属常态,不计时 |
| 照片证据 | **仅在清晰且能辨认人脸时**做比对 | 模糊照片不参与评分 |
| 行为特征 | 新注册即认领、惯常以“朋友”名义认领 | 老账号、如实声明不触发 |
| 团伙特征 | 一车被多个陌生人认领、重复认领、共用设备/IP、中介网络 | 运营车辆豁免设备/IP 关联 |

### 「认定关联」的分级

- `:verified` —— 登记所有人 / 登记使用人 / 同户成员 / 已核验的关系备案(在违法发生时有效)
- `:weak` —— 当事人自称的亲友关系,或系统里未核验的备案
- `:none` —— 查无任何关联

只有 `:none` 计入“陌生车辆”统计;`:weak` 单独低权重处理,绝不直接当成撒谎。

### 「重复认领」的特殊处理

同一条违法被两人认领,只能证明**其中有人撒谎**,证明不了是哪一个。据此对双方
都作不利认定,恰恰会冤枉真正的驾驶人。所以重复认领**不列为硬信号**,只升到
“转人工”,由人工结合其它材料判断。

## 统计窗口为什么不是“案发前 365 天”

分贩子的前几次认领,若只看“案发之前”就看不到后续继续替陌生车背分,早期认领
全部漏网。正确口径是「**存在某个包含本案的 12 个月滚动窗口,此人为 N 辆陌生车
认领**」——既抓住整条行为链,又仍可解释、可申辩(描述一个完整计分周期内的客观
行为集合,而非拿案发后的行为倒推案发时的主观状态)。

## 用法

```bash
# 校验数据
ruby bin/score_theft validate data/sample_claims.json

# 批量研判,人类可读报告
ruby bin/score_theft assess data/sample_claims.json

# 机器可读 JSON(便于接入工单/审核系统)
ruby bin/score_theft assess data/sample_claims.json --json > out.json

# 用自定义策略文件
ruby bin/score_theft assess data/sample_claims.json --policy policy.json

# 单人画像(某人在窗口内的全部疑点)
ruby bin/score_theft profile data/sample_claims.json P3001
```

嵌入代码:

```ruby
require_relative 'lib/score_theft'

dataset = ScoreTheft::Dataset.from_file('data/sample_claims.json')
engine  = ScoreTheft::Engine.new(dataset)

# 单条认领
decision = engine.analyzer.assess(dataset.claims.first)
decision.level            # => :clear / :review / :reject / :evidence_insufficient
decision.auto_accept?     # 能否直接自动计入记分
decision.requires_human?  # 是否需要人工介入
decision.adverse_finding? # 是否为需复核的不利认定
decision.signals.findings.each { |f| puts f.message }  # 逐条依据

# 整批
result = engine.run        # Hash,含 summary 与逐条明细
```

## 数据结构

见 `data/sample_claims.json`。要点:

- `people[].household_id` —— 同户号,用来认定家人共用车辆
- `people[].account_created_at` —— 账号注册时间(新号识别)
- `vehicles[].owners[] / registered_drivers[]` —— 带 `since`/`until` 区间的登记关系
- `vehicles[].kind` —— `private`(默认)/ `rental` / `fleet`
- `relationships[]` —— 关系备案,带 `verified` 标志与有效期
- `claims[].photo` —— `quality`(`clear`/`blurry`/`none`)、`face_visible`、`face_match_score`
- `claims[].location{lat,lon}` —— 违法地点,用于时空矛盾
- `claims[].device_id` / `ip` —— 提交设备与出口,用于团伙关联

数据脏了不会静默吞掉:`validate!` 会报出悬空引用、缺失时间等问题。

## 策略与阈值

全部阈值集中在 `lib/score_theft/policy.rb`,可整体用 `--policy` 覆盖,无需改代码。
阈值调整属于执法政策决定,建议留档并说明依据。

## 测试

```bash
ruby test/score_theft_test.rb
```

测试重点不是“抓得多”,而是钉住这些**绝不能误判**的边界:夫妻共用一车、家人借车、
模糊照片、代驾开多辆租车都必须通过;而分贩子(含第一次认领)、时空矛盾、团伙特征
必须被识别;重复认领不得自动拒绝任何一方。

## 集成建议

- **两阶段**:先跑 `assess` 自动放行 `:clear`;`:review` / `:reject` / `:evidence_insufficient`
  进人工队列,附上 `findings` 作为复核依据。
- **申诉**:每条结论都带可读的 `message` 与 `evidence`,可直接用于向当事人释明。
- **留痕**:建议记录策略版本(`policy.to_h`)与引擎版本,便于回溯为何作出某项判断。
- **持续校准**:用已知的申诉成功/失败案例回测阈值,关注“假阳性”(冤枉真人)而非只看检出率。
