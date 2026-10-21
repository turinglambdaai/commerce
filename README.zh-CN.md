# Commerce

**所有产品，共用一份商业真相——支付事件进入，签名产品权益输出。**

[![CI](https://github.com/turinglambdaai/commerce/actions/workflows/ci.yml/badge.svg)](https://github.com/turinglambdaai/commerce/actions/workflows/ci.yml) ![Racket](https://img.shields.io/badge/Racket-9F1D20?logo=racket&logoColor=white) [![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE) ![Stage](https://img.shields.io/badge/stage-M1%20Pancake-C15F3C)

[English](README.md) · **中文**

Commerce 是面向独立软件产品家族的渠道中立商业管理面。所有产品通过同一处
创建结账、接收并审计支付事件、投影订单与订阅状态，再把商业结果变成由
[Permit](https://github.com/turinglambdaai/permit) 签发的产品权益。

Commerce 不是支付机构、Merchant of Record、税务引擎、CRM 或 DRM。
Pancake、ZPAY、应用商店与未来渠道负责资金流转；Permit 负责可在本地验证的
签名权益；Commerce 只拥有二者之间可持久化、可重放、可审计的编排过程。

**渠道中立。事件驱动。权益优先。**

## 快速开始

当前版本已经包含纯事件核心、重放冲突防护、订单投影、权益意图、渠道边界、
持久 SQLite 原始事件 journal、Pancake 原始字节验签与一次性订单主动查验、测试
和一条完整的购买演示；订单投影与签发 outbox 已能同事务持久化，Offer policy
已能生成版本固定、完整且经过 Permit 校验的权益快照，签发 outbox 也已具备
owner 安全的租约状态机和事务型 lineage 写入器。

```bash
raco pkg install --auto --name commerce \
  https://github.com/turinglambdaai/commerce.git

racket examples/first-purchase.rkt
```

预期输出：

```text
order ord_demo_001: paid
rights intent: grant taskly-pro-lifetime to customer-demo
duplicate webhook: ignored
```

第一次接触项目请继续阅读 **[快速上手](docs/getting-started.zh-CN.md)**。
[文档导航](docs/README.md) 为每类架构和运维问题指定唯一的规范入口。

## 为什么需要 Commerce？

单个产品可以在一个下午接好一次支付；产品家族不能在每个应用里重复实现
支付验签、重试、退款、订阅续期、凭证找回与许可证签发。

Commerce 建立一条统一边界：

- **产品只理解 Offer 与权益** —— 永远不内嵌渠道 API 密钥或签发私钥。
- **渠道只陈述支付事实** —— 每个 adapter 验证原生协议，再输出同一组精简事件。
- **Permit 只表达授权** —— Commerce 请求签发完整权益快照，应用在本地验证。
- **每次转换都可审计** —— 原始事件不可变保存，重复投递无害，冲突重放关闭失败，
  签发走显式 outbox，不在 Webhook 请求里偷偷完成。

## 家族中的位置

```text
                         产品
                    /      |       \
              Rivet/Glaze Permit  Commerce client
                    UI     本地验权       |
                                         v
                                 Commerce service
                              /          |          \
                       Pancake         ZPAY       应用商店
                              \          |          /
                                  已验证支付事件
                                         |
                                      权益意图
                                         |
                                  Permit issuer
                                         |
                              签名 Permit credential
```

依赖方向不可倒置：

```text
product  -> Rivet 或 Glaze
product  -> Permit
product  -> Commerce client       （需要在线商业能力时才使用）

Commerce service -> 支付渠道
Commerce service -> Permit issuer

Rivet / Glaze / Keel -X-> Commerce
Permit               -X-> Commerce
```

本仓边界见[架构](docs/architecture.md)与[家族集成](docs/family-integration.md)；
[五仓家族架构](https://github.com/turinglambdaai/keel/blob/main/docs/family-architecture.md)
是跨仓依赖、职责与发布顺序的唯一权威来源。

## 核心词汇

| 概念 | 含义 |
| --- | --- |
| Product | 稳定的软件身份，例如 `taskly` |
| Offer | 用户实际购买的方案，例如 `taskly-pro-lifetime` |
| Provider mapping | 实现 Offer 的 Pancake、ZPAY 或商店标识 |
| Payment event | 渠道验证后产生的不可变支付事实 |
| Order projection | Commerce 保存的最小商业状态投影 |
| Rights intent | 授予、续期、替换或收回权益的可审计请求 |
| Issuance | 最终 Permit credential 及其交付状态 |

Commerce 不复制支付渠道的完整商品目录或客户库。渠道对象仍是支付事实源；
Commerce 只保存确定性编排需要的标识、投影和审计证据。

## 公共模块

```racket
(require commerce)           ; 纯领域模型与状态转换
(require commerce/provider)  ; 服务端渠道 adapter 边界
(require commerce/journal)   ; 持久事件接收契约
(require commerce/storage)   ; 持久投影/outbox 操作
(require commerce/storage/sqlite) ; SQLite 服务存储后端
(require commerce/pancake)   ; Pancake 鉴权与主动订单证明
(require commerce/permit)    ; 经审阅的 Offer policy 到 Permit 快照
```

默认的 `commerce` facade 不暴露渠道密钥、原始 Webhook 接收、网络监听、数据库
或 Permit 签名能力。这些能力必须从明确的服务端模块显式引入。

## 当前状态

已经实现：

- 精确整数最小货币单位与稳定 Offer 身份；
- 已验证的规范支付事件；
- 渠道事件幂等与冲突重放拒绝；
- 能正确处理“退款先于支付通知到达”的订单投影；
- 确定性的 `grant` / `withdraw` 权益意图；
- 渠道 adapter 契约与 mock 购买演示；
- 持久 SQLite 原始事件 journal，包含摘要复核、精确重放、冲突拒绝和数据库级
  不可变保护；
- SQLite schema v3，包含 v1/v2 原位迁移、确定性 journal 投影、订单与签发
  outbox 的原子写入，以及只追加且 revision 连续的 entitlement lineage 证据；
- Pancake RSA-SHA256 原始字节验签，包含显式环境密钥、有限重放窗口、mode 绑定
  和脱敏的类型化错误；
- 带商户签名的 Pancake GraphQL 查单：在构造规范支付事件前，将已完成的一次性
  订单与商店、环境、外部结账引用、商品、成功支付、精确币种/金额、稳定主体和
  Offer 全部绑定；
- 显式 `commerce/permit` adapter：复用 Permit 校验版本固定的 Offer policy，
  生成完整 revision 0 grant 或在签发时到期的 withdrawal successor 及其精确字节；
- owner 安全的签发 outbox 租约状态机：租约互斥、attempts 可观察、过期租约可
  回收、owner 校验的完成与类型化释放；完成动作在同一个事务内追加 lineage 根
  加 revision 0（或恰好一个 successor）并完结 outbox 行，重复完成会对账回
  已记录的 revision；
- 双语入口文档、规范架构与 CI 门禁。

尚未实现：

- Webhook HTTP 端点；
- Permit issuer worker（快照签名）与 claim 交付；
- ZPAY 或应用商店 adapter；
- 租约原语之外的退款/运营重放工具、订阅、席位、凭证领取门户或运营后台；
- 生产部署或任何“已通过支付渠道认证”的声明。

下一条受控纵切是 [ROADMAP.md](ROADMAP.md) 定义的显式 issuer worker：用
`permit/issuer` 签发已准备的快照并对模糊崩溃做对账。缺口保持公开，避免把
架构完成误当成生产就绪。

## 开发

```bash
raco pkg install --auto --no-docs --name commerce .
raco make commerce/main.rkt commerce/provider.rkt commerce/journal.rkt \
  commerce/storage.rkt commerce/storage/sqlite.rkt commerce/pancake.rkt \
  commerce/permit.rkt \
  commerce-doc/scribblings/commerce.scrbl
raco test -p commerce
raco setup --check-pkg-deps commerce
```

修改边界前先读 [AGENTS.md](AGENTS.md) 和[架构](docs/architecture.md)。公共 API
变更必须同时提交测试、受影响的中英文入口文档和对应规范文档。

## 许可证

Apache-2.0，见 [LICENSE](LICENSE)。

