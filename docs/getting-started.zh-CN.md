# 快速上手

本教程让第一次接触项目的人从一套空白 Racket 环境走到一笔可审计的购买状态
转换。这里刻意使用 mock 边界：不需要注册账号、配置密钥、访问网络或真的付款。

## 1. 环境要求

- Racket CS 9.0 或更高版本
- Git

## 2. 安装源码链接包

```bash
git clone https://github.com/turinglambdaai/commerce.git
cd commerce
raco pkg install --auto --no-docs --name commerce .
```

普通产品安全地从默认 facade 开始：

```racket
(require commerce)
```

只有服务端渠道 adapter 显式引入：

```racket
(require commerce/provider)
```

需要持久接收已认证事件的服务再显式引入：

```racket
(require commerce/journal
         commerce/journal/sqlite)
```

Pancake 边缘模块在显式环境中认证原始请求字节：

```racket
(require commerce/pancake)

(define verified
  (verify-pancake-webhook raw-body signature-header
                          #:environment 'test))
```

`verified` 仍是渠道原生证据，不是规范支付事件；履约前仍须主动查单。

## 3. 跑通第一笔购买

```bash
racket examples/first-purchase.rkt
```

演示假设 mock adapter 已经完成渠道原生鉴权，然后把支付事件应用到不可变状态。
第一次转换产生一个 `grant` 权益意图；同一渠道事件再次投递时会被正常确认，
不会重复产生权益。

## 4. 修改行为前先读测试

```bash
raco test commerce-test/core-test.rkt commerce-test/journal-test.rkt \
  commerce-test/pancake-test.rkt
```

测试直接回答首批最难的问题：

- 渠道重复投递同一个 Webhook 怎么办？
- 同一个 event id 被不同内容重用怎么办？
- 退款通知比支付成功更早到达怎么办？
- 两条成功通知为什么不会签发两次？
- 同一个订单的金额或 Offer 被改动时怎么办？
- 什么证据能证明确认结果可以跨服务重启保留？
- 实际写出的数据库行是什么，普通 SQL 能否篡改它？
- Pancake 到底签了哪些原始字节，过期、跨环境或有歧义的已签请求如何关闭失败？

## 5. 理解边界

按顺序阅读：

1. [核心概念](concepts.md)
2. [架构](architecture.md)
3. [渠道契约](provider-contract.md)
4. [Permit 集成](permit-integration.md)
5. [安全](security.md)

不要拿渠道 SDK 的 happy path 示例直接开写 adapter。先在渠道契约中明确鉴权方式、
重试行为、主动查单 API、退款语义、测试模式和固定测试证据。

## 6. 跑完整门禁

```bash
raco make commerce/main.rkt commerce/provider.rkt commerce/journal.rkt \
  commerce/journal/sqlite.rkt commerce/pancake.rkt \
  commerce-doc/scribblings/commerce.scrbl
raco test -p commerce
raco setup --check-pkg-deps commerce
```

首个真实渠道是 Pancake。签名协议一致性已经实现；主动查单、持久处理与真实
sandbox 证据仍是 [ROADMAP.md](../ROADMAP.md) 中彼此独立的 M1 门禁。

