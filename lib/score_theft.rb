# frozen_string_literal: true

# ScoreTheft —— 违章认领环节的「顶替扣分」(买分卖分)识别引擎。
#
# 设计原则(重要,决定了所有阈值和权重的取向):
#
#   1. 只对「存在的、指向欺诈的证据」加分。缺失的数据 —— 尤其是
#      看不清人脸的照片 —— 一律视为「证据不足」,不产生任何不利推断。
#      把“没看到”当成“看到了相反的”,是冤假错案最主要的来源。
#
#   2. 单张照片、单一信号永远不能直接判为顶替。照片模糊是常态,
#      家人朋友借车也是常态。只有多个相互独立的信号(关系、数量、
#      时间、行为、团伙)共同指向时,风险分才会高到需要拒绝。
#
#   3. 「拒绝」档一律附带人工复核要求(human_confirmation_required)。
#      引擎输出的是研判结论和行动建议,不是终局处罚决定。
#
#   4. 每个结论都必须可解释:列出命中的信号、权重和依据,
#      让当事人可以陈述申辩。
module ScoreTheft
  VERSION = '1.0.0'

  # 无关联车辆、异常行为等统计量的判定口径
  CATEGORY_CAPS = {
    relationship: 45.0,
    volume:       40.0,
    temporal:     25.0,
    photo:        45.0,
    behavioral:   30.0,
    collusion:    40.0
  }.freeze

  CATEGORY_LABELS = {
    relationship: '关联核验',
    volume:       '数量异常',
    temporal:     '时间异常',
    photo:        '照片证据',
    behavioral:   '行为特征',
    collusion:    '团伙特征'
  }.freeze
end

require 'json'
require 'time'
require 'set'

require_relative 'score_theft/time_parse'
require_relative 'score_theft/util'
require_relative 'score_theft/models'
require_relative 'score_theft/dataset'
require_relative 'score_theft/finding'
require_relative 'score_theft/policy'
require_relative 'score_theft/relation_resolver'
require_relative 'score_theft/collusion'
require_relative 'score_theft/signals'
require_relative 'score_theft/analyzer'
require_relative 'score_theft/engine'
require_relative 'score_theft/report'
