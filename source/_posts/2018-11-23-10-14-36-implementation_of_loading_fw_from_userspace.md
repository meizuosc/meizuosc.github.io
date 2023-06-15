---
layout: post
title: "kernel 空间加载用户空间fw实现原理"
keywords: [ "firmware","uevent" ]
description: ""
category: "linux"
tags: [ "firmware","uevent" ]
author: Qu dishui
permalink: /implementation-of-loading-fw-from-userspace.html
---

随着手机外围器件的集成度和复杂度越来越高, 单纯的设置相关寄存器已经无法使得器件可以正常的工作. 在一般情况下，需要将一个特定的fw下载到器件中, 确保器件可以正常稳定的运行, 比如：camera ois，camera actuator， TP等等. 一般情况下, 有以下三种方案:

* 直接将fw data转化为特定的数组，编码在驱动代码中.
* 将fw data烧录到一个分区中，需要的时候从分区中load进来.
* 将fw打包到某个镜像中，如vendor，system等等，需要的时候从用户空间中load到kernel空间中.

对于方案1, 直接将其硬编码在驱动代码中, 会造成kernel镜像size变大, 有可能造成镜像超限, 导致kernel启动失败; 并且调试也不方便, 每次修改fw都需要重新编译内核.

对于方案2, 需要实现预留好空间, 某些时候可能无法满足; 并且一般重新烧录fw, 一般机器需要进入特定的模式, 不利于在线调试.

对于方案3,  能够有效的避免前两种方案的不足, 在驱动中应用比较广泛, 也是本文叙述的主题.

下文主要从编程步骤出发, 通过调用的接口来具体分析其中实现的机制.

### 一 编程步骤 ###

linux内核为方案3提供了完整的解决方案, 驱动开发起来也相当的方便, 具体的步骤如下:

1. 在编译的时候, 将fw打包到具体镜像中. 对于android系统，可以将fw放在/etc/firmware, /vendor/firmware, /firmware/image这几个目录. 当上层服务ueventd接收到kernel上报的请求fw的uevent事件, 会依次搜索这几个目录, 查找对应名称的fw, 并通过节点data传递给kernel.
2. 由于内核已经封装好了接口, 驱动代码比较简单, 具体如下:

```
#include<linux/firmware.h>
 ....
xxx_func() {
const struct firmware *fw=NULL;`
......
request_firmware(&fw, fw_name, dev);
.......
release_firmware();
}
```

有上面的步骤可知, 内核已经把接口封装的相当简洁, 使用简单的接口就可以完成load 用户空间的fw任务. 当然kernel还为我们提供了其他类型接口, 主要是提供了一些其他的特性, 满足特定条件下load 用户空间的fw. 例如, 如果在原子上下文load fw，则只能用request_firmware_nowait()接口, 该接口不会导致进程睡眠. 但是所有的这些接口, 其工作原理是一样, 因此下文将以request_firmware()为入口分析load用户空间fw的原理.
### 二 实现原理分析 ###
#### 2.1 相关结构体介绍 ####
理解代码最好的入口是熟悉代码使用的数据结构, 理解了代码使用的数据结构, 就基本上可以对代码的实现原理有一个初步的认识. 所以下面熟悉一下相关的数据结构.

* firmware 结构体

```
路径:include/linux/firmware.h
struct firmware {
        size_t size;
        const u8 *data;
        struct page **pages;

        /* firmware loader private fields */
        void *priv;
};
```

该结构体主要用于向驱动导出load 到内核的fw信息, 成员含义如下:
size: firmware 数据的大小.
data: firmware数据.
pages: 指向fw data存储的物理页面.
priv: 私有数据指针.

* builtin_fw 结构体

```
路径:include/linux/firmware.h
struct builtin_fw {
        char *name;
        void *data;
        unsigned long size;
};
```

该结构主要用于描述编译到内核builtin_fw段的fw, 成员含义如下:
name: firmware 数据的名称.
data: 指向firmware数据的指针.
size: firmware的大小.

* firmware_buf结构体

```
路径:driver/base/firmware_class.c
struct firmware_buf {
        struct kref ref;
        struct list_head list;
        struct completion completion;
        struct firmware_cache *fwc;
        unsigned long status;
        void *data;
        size_t size;
        size_t allocated_size;
#ifdef CONFIG_FW_LOADER_USER_HELPER
        bool is_paged_buf;
        bool need_uevent;
        struct page **pages;
        int nr_pages;
        int page_array_size;
        struct list_head pending_list;
#endif
        const char *fw_id;
};
```

该结构体主要用于存储fw data,以及一些控制状态等等. 部分重要的成员解释如下:
completion: 完成量,用于在load fw完成时, 唤醒等待的进程.
fwc: 指向全局的fw_cache, 该结构保存了已经load 的fw的相关信息.
status: 保存当前的状态.
data: 指向保存fw data的kernel虚拟地址.
size: fw 的大小.
pages: 指向存储fw data的物理页.
page_array_size: 分配的物理页的数目.
fw_id: fw 的名称.
#### 2.2 实现原理分析 ####
request_firmware()和request_firmware_nowait()等接口都是_request_firmware()的一个前端, 仅仅只是传进的参数不一样而已, 因此基于分析request_firmware()的实现来探讨其实现原理, request_firmware()如下:

```
路径:driver/base/firmware_class.c
int
request_firmware(const struct firmware **firmware_p, const char *name,
		 struct device *device)
{
	int ret;

	/* Need to pin this module until return */
	__module_get(THIS_MODULE);
	ret = _request_firmware(firmware_p, name, device, NULL, 0,
				FW_OPT_UEVENT | FW_OPT_FALLBACK);
	module_put(THIS_MODULE);
	return ret;
}
```

下面来看看_request_firmware()函数的实现:

```
路径:driver/base/firmware_class.c
static int
_request_firmware(const struct firmware **firmware_p, const char *name,
                  struct device *device, void *buf, size_t size,
                  unsigned int opt_flags)
{
......
        ret = _request_firmware_prepare(&fw, name, device, buf, size,
                                        opt_flags);
        if (ret <= 0) /* error or already assigned */
                goto out;

......

         ret = fw_get_filesystem_firmware(device, fw->priv);
         if (ret) {
                 if (!(opt_flags & FW_OPT_NO_WARN))
                         dev_dbg(device,
                                  "Firmware %s was not found in kernel paths. rc:%d\n",
                                  name, ret);
                 if (opt_flags & FW_OPT_USERHELPER) {
                         dev_err(device, "[%s]Falling back to user helper\n", __func__);
                         ret = fw_load_from_user_helper(fw, name, device,
                                                        opt_flags, timeout);
                 }
         }
......
	 if (!ret)
	        ret = assign_firmware_buf(fw, device, opt_flags);
......
 }
```

在该函数中，会依次从4个地方尝试load 相应的fw, 具体如下:

* 从内核中相应的段中查找是否有符合要求的firmware.
* 从cache中查找是否有上次load相应的还没有换出firmware.
* 直接利用内核中文件接口中读取相应的firmware.
* 利用uevent接口load相应的firmware.

其中, 对于第1种和第2种情况是在_request_firmware_prepare()函数中完成的; 第3种情况是在_request_firmware_prepare()函数中完成的; 第4种情况是在fw_load_from_user_helper()函数中完成的.

对于第1种情况, 其具体的实现在fw_get_builtin_firmware()函数中, 原理是通过遍历builtin_fw段的firmware, 并比较firmware的name是否相同, 如果相同, 表示匹配上,则将firmware的size和data赋值给驱动传过来的firmware结构体指针, request_firmware就完成load firmware功能, 具体如下:

```
路径:drivers/base/firmware_class.c
static int
_request_firmware_prepare(struct firmware **firmware_p, const char *name,
                          struct device *device, void *dbuf, size_t size,
                          unsigned int opt_flags)
{
.......
        *firmware_p = firmware = kzalloc(sizeof(*firmware), GFP_KERNEL);
        if (!firmware) {
                dev_err(device, "%s: kmalloc(struct firmware) failed\n",
                        __func__);
                return -ENOMEM;
        }

        if (fw_get_builtin_firmware(firmware, name, dbuf, size)) {
                dev_dbg(device, "using built-in %s\n", name);
                return 0; /* assigned */
        }

.......
}

路径:drivers/base/firmware_class.c
static bool fw_get_builtin_firmware(struct firmware *fw, const char *name,
                                    void *buf, size_t size)
{
        struct builtin_fw *b_fw;

        for (b_fw = __start_builtin_fw; b_fw != __end_builtin_fw; b_fw++) {
                if (strcmp(name, b_fw->name) == 0) {
                        fw->size = b_fw->size;
                        fw->data = b_fw->data;

                        if (buf && fw->size <= size)
                                memcpy(buf, fw->data, fw->size);
                        return true;
                }
        }

        return false;
}
```

对于第2种情况, 其具体的实现在fw_lookup_and_allocate_buf()函数中, 匹配原理和第1种情况相同, 只不过查找实在全局变量fw_cache的链表上查找. fw_cache的 head链表上保存了以前load过的fw的信息,比如name, data, size等等. 其中在函数sync_cached_firmware_buf()中主要检查fw是否已经load到内核空间, 如果没有, 则等待; 否在就调用fw_set_page_data(), 将fw相关的信息赋值到驱动的firmware结构体指针, 具体如下:

```
路径:drivers/base/firmware_class.c
static int
_request_firmware_prepare(struct firmware **firmware_p, const char *name,
                          struct device *device, void *dbuf, size_t size,
                          unsigned int opt_flags)
{
........

        ret = fw_lookup_and_allocate_buf(name, &fw_cache, &buf, dbuf, size,
                                        opt_flags);

        /*
         * bind with 'buf' now to avoid warning in failure path
         * of requesting firmware.
         */
        firmware->priv = buf;

        if (ret > 0) {
                ret = sync_cached_firmware_buf(buf);
                if (!ret) {
                        fw_set_page_data(buf, firmware);
                        return 0; /* assigned */
                }
        }
.......
}

路径:drivers/base/firmware_class.c
static int fw_lookup_and_allocate_buf(const char *fw_name,
                                      struct firmware_cache *fwc,
                                      struct firmware_buf **buf, void *dbuf,
                                      size_t size, unsigned int opt_flags)
{
        struct firmware_buf *tmp;

        spin_lock(&fwc->lock);
        if (!(opt_flags & FW_OPT_NOCACHE)) {
                tmp = __fw_lookup_buf(fw_name);
                if (tmp) {
                        kref_get(&tmp->ref);
                        spin_unlock(&fwc->lock);
                        *buf = tmp;
                        return 1;
                }
        }
.......
}
```

对于第3种情况, 依据内核预先定义好的路径fw_path调用内核文件读写接口kernel_read_file_from_path load入相应的fw, 在fw_finish_direct_load()函数中做了一些load fw后的清理工作,比如设置完成标志等等.

```
路径:drivers/base/firmware_class.c
static int
fw_get_filesystem_firmware(struct device *device, struct firmware_buf *buf)
{
......

        for (i = 0; i < ARRAY_SIZE(fw_path); i++) {
                /* skip the unset customized path */
                if (!fw_path[i][0])
                        continue;

                len = snprintf(path, PATH_MAX, "%s/%s",
                               fw_path[i], buf->fw_id);
                if (len >= PATH_MAX) {
                        rc = -ENAMETOOLONG;
                        break;
                }

                 buf->size = 0;
                 rc = kernel_read_file_from_path(path, &buf->data, &size, msize,
                                                 id);
                 if (rc) {
                         if (rc == -ENOENT)
                                 dev_dbg(device, "loading %s failed with error %d\n",
                                          path, rc);
                         else
                                 dev_warn(device, "loading %s failed with error %d\n",
                                          path, rc);
                         continue;
                 }
                 dev_dbg(device, "direct-loading %s\n", buf->fw_id);
                 buf->size = size;
                 fw_finish_direct_load(device, buf);
                 break;
         }
......
 }
```

fw_path具体的定义如下, 其中fw_path_para主要用于用户传递定制的路径.

```
static const char * const fw_path[] = {
        fw_path_para,
        "/data/vendor/vibrator",
        "/lib/firmware/updates/" UTS_RELEASE,
        "/lib/firmware/updates",
        "/lib/firmware/" UTS_RELEASE,
        "/lib/firmware"
};
```

当在前三种情况下无法找到对应的fw时,就会进入第4种情况进行查找, 其工作在函数为fw_load_from_user_helper()种实现, 具体如下:

```
static int fw_load_from_user_helper(struct firmware *firmware,
                                    const char *name, struct device *device,
                                    unsigned int opt_flags, long timeout)
{
        struct firmware_priv *fw_priv;

        fw_priv = fw_create_instance(firmware, name, device, opt_flags);
        if (IS_ERR(fw_priv))
                return PTR_ERR(fw_priv);

        fw_priv->buf = firmware->priv;
        return _request_firmware_load(fw_priv, opt_flags, timeout);
}
```

在函数 fw_create_instance() 主要进行了一些设备的初始化工作, 如设备所属的class, groups等等. 具体如下:

```
static struct firmware_priv *
fw_create_instance(struct firmware *firmware, const char *fw_name,
                   struct device *device, unsigned int opt_flags)
{
        struct firmware_priv *fw_priv;
        struct device *f_dev;

        fw_priv = kzalloc(sizeof(*fw_priv), GFP_KERNEL);
        if (!fw_priv) {
                fw_priv = ERR_PTR(-ENOMEM);
                goto exit;
        }

        fw_priv->nowait = !!(opt_flags & FW_OPT_NOWAIT);
        fw_priv->fw = firmware;
        f_dev = &fw_priv->dev;

        device_initialize(f_dev);
        dev_set_name(f_dev, "%s", fw_name);
        f_dev->parent = device;
        f_dev->class = &firmware_class;
        f_dev->groups = fw_dev_attr_groups;
exit:
        return fw_priv;
}
```

其中重点看一下 fw_dev_attr_groups属性集合, 由linux 设备驱动框架原理,当该设备加入到系统中时,会在该设备下生成两个节点data和loading, 后面讲到这两个节点的用处.

```
路径:driver/base/firmware_class.c
static const struct attribute_group *fw_dev_attr_groups[] = {
        &fw_dev_attr_group,
        NULL
};

static const struct attribute_group fw_dev_attr_group = {
        .attrs = fw_dev_attrs,
        .bin_attrs = fw_dev_bin_attrs,
};

static struct bin_attribute *fw_dev_bin_attrs[] = {
        &firmware_attr_data,
        NULL
};

static struct attribute *fw_dev_attrs[] = {
        &dev_attr_loading.attr,
        NULL
};

static struct bin_attribute firmware_attr_data = {
        .attr = { .name = "data", .mode = 0644 },
        .size = 0,
        .read = firmware_data_read,
        .write = firmware_data_write,
};

static DEVICE_ATTR(loading, 0644, firmware_loading_show, firmware_loading_store);
```

在_request_firmware_load()函数中, 首先调用device_add()函数将设备注册到系统中, 接着调用kobject_uevent()函数向用户空间上报uevent事件, 最后调用wait_for_completion_killable_timeout()函数等待load fw完成.
loading节点写函数如下:

```
路径:driver/base/firmware_class.c
 static ssize_t firmware_loading_store(struct device *dev,
                                       struct device_attribute *attr,
                                       const char *buf, size_t count)
 {
......

         switch (loading) {
         case 1:
                 /* discarding any previous partial load */
                 if (!test_bit(FW_STATUS_DONE, &fw_buf->status)) {
                         for (i = 0; i < fw_buf->nr_pages; i++)
                                 __free_page(fw_buf->pages[i]);
                         vfree(fw_buf->pages);
                         fw_buf->pages = NULL;
                         fw_buf->page_array_size = 0;
                         fw_buf->nr_pages = 0;
                         set_bit(FW_STATUS_LOADING, &fw_buf->status);
                 }
                 break;
         case 0:
                 if (test_bit(FW_STATUS_LOADING, &fw_buf->status)) {
                         int rc;

                         set_bit(FW_STATUS_DONE, &fw_buf->status);
                         clear_bit(FW_STATUS_LOADING, &fw_buf->status);

......
                         rc = fw_map_pages_buf(fw_buf);
......
                         complete_all(&fw_buf->completion);
                         break;
                 }
......
         }
......
}
```

当应用程序将fw写入到data节点时,  如果buf->data已经映射到kernel虚拟地址空间,则调用firmware_rw_buf()直接将fw data copy到buf->data中; 如果buf->data为NULL, 则首先调用fw_realloc_buf()函数, 分配物理页, 然后调用firmware_rw()函数将fw data 拷贝到分配的物理页中.
data节点写函数如下:

```
路径:driver/base/firmware_class.c
static ssize_t firmware_data_write(struct file *filp, struct kobject *kobj,
                                   struct bin_attribute *bin_attr,
                                   char *buffer, loff_t offset, size_t count)
{
......

        if (buf->data) {
                if (offset + count > buf->allocated_size) {
                        retval = -ENOMEM;
                        goto out;
                }
                firmware_rw_buf(buf, buffer, offset, count, false);
                retval = count;
        } else {
                retval = fw_realloc_buffer(fw_priv, offset + count);
                if (retval)
                        goto out;

                retval = count;
                firmware_rw(buf, buffer, offset, count, false);
        }
.....
}
```

当应用程序向该节点写入1时, 如果status的状态不是FW_STATUS_DONE, 则进行一些初始化工作, 为后续load fw做准备工作,  并将status状态设备为FW_STATUS_LOADING.

当应用程序向该节点写入0时, 设置status的状态为FW_STATUS_DONE, 并调用fw_map_pages_buf函数将保存fw data的pages映射到kernel虚拟地址空间, 变为内核可操作的数据. 然后调用complete_all 唤醒等待的进程. 进程唤醒后,会执行assign_firmware_buf()函数, 将保存在firmware_buf结构中fw信息赋值给request_firmware()的第一个参数, 从而完成fw 的load工作.

```
路径:driver/base/firmware_class.c
static int assign_firmware_buf(struct firmware *fw, struct device *device,
                               unsigned int opt_flags)
{
......
        /* pass the pages buffer to driver at the last minute */
        fw_set_page_data(buf, fw);
......
}
static void fw_set_page_data(struct firmware_buf *buf, struct firmware *fw)
{
        fw->priv = buf;
#ifdef CONFIG_FW_LOADER_USER_HELPER
        fw->pages = buf->pages;
#endif
        fw->size = buf->size;
        fw->data = buf->data;

        pr_debug("%s: fw-%s buf=%p data=%p size=%u\n",
                 __func__, buf->fw_id, buf, buf->data,
                 (unsigned int)buf->size);
}
```

### 三 结束语 ###
本文以request_firmware()为入口详细探讨了内核load fw的实现原理, 以期大家对这个模块有一个全面的认识. 欢迎大家批评指正, 谢谢！
