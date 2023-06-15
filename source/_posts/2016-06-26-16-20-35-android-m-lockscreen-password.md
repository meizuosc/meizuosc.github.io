---
layout: post
title: "剖析 Android M 锁屏密码存储方式"
keywords: ["锁屏","密码","Android","lockcreen","password"]
categories:
  - "安全"
tags:
  - "Android"
  - "lockcreen"
  - "锁屏"
  - "密码"
author: Dong Liyuan
permalink: /lockcreen-password.html
---

## Android M 之前锁屏密码的存储

在 Android M 之前，锁屏密码的存储格式很简单，其使用了 64 位随机数作为 salt 值，此 salt 值被存储在 SQLite 数据库 `/data/system/locksettings.db` 中。密码在存储的时候，会将输入的密码加上此随机数组成新的字符串。然后对新的字符串分别进行 SHA-1 和 MD5 加密，将加密后的密文通过 MD5 + SHA-1 的方式进行字符串拼接，组成新的密文存储在 `/data/system/password.key` 中，共有 72 位。其加密后的形式如下：

```
/data/system # cat password.key
B40C2F6FE4E89F3386D4E689B135304410D64951914FB35770FDAC58B694177B29297A80
```

而密码的详细信息，存储在 `/data/system/device_policies.xml` 中，内容类似如下：

```
/data/system # cat device_policies.xml
<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
<policies setup-complete="true">
<active-password quality="196608" length="4" uppercase="0" lowercase="0" letters="0" numeric="4" symbols="0" nonletter="4" />
</policies>
```

其中主要用到的两个字段 quality 是密码的类型，简单密码和复杂密码的值不同，length 是密码的长度，其他字段存储密码中各种字符的数量。

## Android M 中锁屏密码的存储

在 Android M 中，锁屏密码的存储格式发生了变化，其默认的存储格式在 `/system/gatekeeper/include/gatekeeper/password_handle.h` 中描述如下：

```
typedef uint64_t secure_id_t;
typedef uint64_t salt_t;
/**
 * structure for easy serialization
 * and deserialization of password handles.
 */
static const uint8_t HANDLE_VERSION = 2;
struct __attribute__ ((__packed__)) password_handle_t {
    // fields included in signature
    uint8_t version;
    secure_id_t user_id;
    uint64_t flags;

    // fields not included in signature
    salt_t salt;
    uint8_t signature[32];

    bool hardware_backed;
};
```

其中 version 默认是 2，user_id 是 Android 用户 id ，signature 存储的便是密文，hardware_backed 存储的是加密方式，0 表示密文是软件加密，而 1 表示密文是通过 TEE 环境进行加密得到的。

密码加密后默认以 `password_handle_t` 格式存储在 `/data/system/gatekeeper.password.key` 中。密码的生成和校验，在 HAL 层是通过 `system/core/gatekeeperd/gatekeeperd.cpp` 中的函数实现的。其在系统启动时被注册为 gatekeeperd 服务，服务在启动的时候会调用 `GateKeeperProxy()` 对象，此类的构造函数会去查找 TEE module，如果找到，则通过 TEE 设备进行加解密，如果没有找到，则通过一个软件设备进行加解密。

这里主要分析下通过软甲设备解密的逻辑。解密时，会调用到 `system/core/gatekeeperd/gatekeeperd.cpp` 中的以下函数：

```
int verify(uint32_t uid, const uint8_t *enrolled_password_handle,
            uint32_t enrolled_password_handle_length,
            const uint8_t *provided_password, uint32_t provided_password_length,
            bool *request_reenroll)
```

在此函数中，由于没有使用 TEE，所以会调用到软件设备验证 `system/core/gatekeeperd/SoftGateKeeperDevice.cpp` 中的：

```
int SoftGateKeeperDevice::verify(uint32_t uid,
		uint64_t challenge, const uint8_t *enrolled_password_handle,
		uint32_t enrolled_password_handle_length, const uint8_t *provided_password,
		uint32_t provided_password_length, uint8_t **auth_token, uint32_t *auth_token_length,
		bool *request_reenroll)
```

函数进行校验，此函数对传进来的信息进行处理后交到 `system/gatekeeper/gatekeeper.cpp` 中的

```
void GateKeeper::Verify(const VerifyRequest &request, VerifyResponse *response)
```

进行处理，在这里对参数进行一系列处理和重新组织后再交给

```
bool GateKeeper::DoVerify(const password_handle_t *expected_handle, const SizedBuffer &password)
```

进行校验，在此函数中，再调用

```
bool GateKeeper::CreatePasswordHandle(SizedBuffer *password_handle_buffer, salt_t salt,
		secure_id_t user_id, uint64_t flags, uint8_t handle_version, const uint8_t *password,
		uint32_t password_length)
```

将上面提到的 `/data/system/gatekeeper.password.key` 文件中存储的信息进行解析，然后调用

```
ComputePasswordSignature(password_handle->signature, sizeof(password_handle->signature),
            password_key, password_key_length, to_sign, sizeof(to_sign), salt);
```

函数将输入的密码进行加密，从这里可以看到，输入的密码要加密成密文只需要用到存储的密码中的 salt 值，此函数在 `system/core/gatekeeperd/SoftGateKeeper.h` 中，其调用 crypto 库中的

```
crypto_scrypt(password, password_length, reinterpret_cast<uint8_t *>(&salt),
				sizeof(salt), N, r, p, signature, signature_length);
```

将输入的密码存储在 signature 中并返回。此函数最终会通过 SHA256 进行加密，参数中的 N, r, p 默认为如下值：

```
static const uint64_t N = 16384;
static const uint32_t r = 8;
static const uint32_t p = 1;
```

通过以上处理后对输入的密码加密后得到的密文与手机中存储的密文进行比较后返回校验结果，从而判断输入的密码的正确与否。

在 Android M 中，改变了之前直接在 Java 层进行密码校验的方式，将密码的校验通过 HAL 层的服务进行处理，同时加入对 TEE 的支持，使得锁屏密码的安全性大大提升，同时也可以方便的支持其他的安全特性，提升了整个系统的安全性。
