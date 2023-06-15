---
layout: post
title: "Android M 外部存储剖析 "
keywords: ["sdcard", " 权限 ", "runtime","fuse"]
categories:
  - "存储"
tags:
  - "外置存储"
  - "Android"
author: Wenjun Zhang
permalink: /android-m-external-storage.html
---

> 这篇文章是建立在你已经对 Android 外部存储的基础知识有一定了解的基础之上，如果之前并不是太了解这个部分，阅读起来可能会比较费劲，可以先阅读参考下面文章：<http://blog.csdn.net/zjbpku/article/details/25161131>

## Android M 外部存储的变化

从 Android 6.0 开始，Android 支持移动存储（adoptable storage），例如 SD 卡或者 USB 。移动存储可以像内部存储一样加密和格式化，可以存储所有类型的应用数据。

### 权限变化

是否访问外部存储由各种 Android 权限保护。

* 从 Android 1.0 开始，写访问需要 `WRITE_EXTERNAL_STORAGE` 权限。
* 从 Android 4.0 开始，读访问需要 `READ_EXTERNAL_STORAGE` 权限。
* 从 Android 4.4 开始，外部存储设备上的文件，也能够基于目录结构来合成（ synthesized ）不同的 DAC 权限（ owner，group，mode ）。这允许应用能够在外部存储上管理一个包相关的目录，而无需 `WRITE_EXTERNAL_STORAGE` 权限。例如， 应用 com.example.foo 可以自由访问外部存储上的 Android/data/com.example.foo/ 。这种合成权限是通过 fuse 守护来包裹原始存储设备来完成的。
* Android 6.0 引入了新的运行时权限（runtime permissions ）模型，用于应用在运行中必要时申请权限。由于新模型包含了 READ/WRITE_EXTERNAL_STORAGE ，因此平台需要在不杀死或者重启运行中的应用的前提下，动态对存储访问授权。

#### 关于运行时权限

Android 6.0 引入了一个新的应用权限模型，期望对用户更容易理解，更易用和更安全。该模型将标记为危险的权限从安装时权限 ( Install Time Permission ) 模型移动到运行时权限模型（ Runtime Permissions ）:

* 安装时权限模型 ( Android 5.1 以及更早 )。用户在应用安装和更新时，对危险权限授权。但是 OEM 和运行商预装的应用将自动预授权。
* 运行时权限 ( Android 6.0 及以后 )。用户在应用运行时，对应用授予危险权限。由应用决定何时去申请权限（例如，在应用启动时或者用户访问某个特性时），但必须允许用户来授予或者拒绝应用对特定权限组的访问。OEM 和运营商可以预装应用，但是不能对权限进行预授权（例外情况请看这里 Create exception ）。

运行时权限提供给用户关于应用所需权限更多的相关上下文和可视性，这也让开发者帮助用户更好的理解：为什么应用需要所请求的权限，授权将有什么样的好处，拒绝将有何种不便。用户可以通过设置中的菜单来撤销应用的权限。

### 目录的变化

**Android L:**

```sh
on init
    # See storage config details at http://source.android.com/tech/storage/
    mkdir /mnt/shell/emulated 0700 shell shell
    mkdir /storage/emulated 0555 root root

    export EXTERNAL_STORAGE /storage/emulated/legacy
    export EMULATED_STORAGE_SOURCE /mnt/shell/emulated
    export EMULATED_STORAGE_TARGET /storage/emulated

    # Support legacy paths
    symlink /storage/emulated/legacy /sdcard
    symlink /storage/emulated/legacy /mnt/sdcard
    symlink /storage/emulated/legacy /storage/sdcard0
    symlink /mnt/shell/emulated/0 /storage/emulated/legacy
```

```
root@mx5:/mnt # ls -l
drwxr-xr-x root     system            2016-07-08 16:20 asec
dr-xr-xr-x root     root              2014-08-14 20:41 cd-rom
drwx------ media_rw media_rw          2016-07-08 16:20 media_rw
drwxr-xr-x root     system            2016-07-08 16:20 obb
lrwxrwxrwx root     root              2016-07-08 16:20 sdcard -> /storage/emulated/legacy
lrwxrwxrwx root     root              2016-07-08 16:20 sdcard2 -> /storage/sdcard1
drwx------ root     root              2016-07-08 16:20 secure
drwxr-x--- shell    sdcard_r          2016-07-08 16:20 shell
```

```
root@mx5:/sdcard # ls -l
drwxrwx--x root     sdcard_r          2016-07-07 10:33 Android
drwxrwx--- root     sdcard_r          2015-01-01 00:00 Customize
drwxrwx--- root     sdcard_r          2015-01-01 00:00 DCIM
drwxrwx--- root     sdcard_r          2016-07-05 19:55 Download
drwxrwx--- root     sdcard_r          2015-01-01 00:00 Movies
drwxrwx--- root     sdcard_r          2015-01-01 00:00 Music
drwxrwx--- root     sdcard_r          2015-01-01 00:00 Pictures
```

在 Android L 上 , 访问 sdcard 的安全主要是通过用户组和权限来控制，详细介绍可以阅读本文开头的链接，这里就不赘述了。

**Android M:**

```sh
# set up the global environment
on init
    export ANDROID_STORAGE /storage
    export EXTERNAL_STORAGE /sdcard
    export ASEC_MOUNTPOINT /mnt/asec
```

```
lrwxrwxrwx root     root              1970-10-09 20:28 sdcard -> /storage/self/primary
```
所以，在 Android M 上 , **/storage/self** 是访问 sdcard 的关键路径。这个路径非常重要，会在后面的原理介绍中讲到。

### 实现原理

#### Step 1: sdcard 挂载

不得已，首先得挂一串代码出来：*/system/core/sdcard/sdcard.c*

```c
static int fuse_setup(struct fuse* fuse, gid_t gid, mode_t mask) {
    char opts[256];

    fuse->fd = open("/dev/fuse", O_RDWR);
    if (fuse->fd == -1) {
        ERROR("failed to open fuse device: %s\n", strerror(errno));
        return -1;
    }

    umount2(fuse->dest_path, MNT_DETACH);

    snprintf(opts, sizeof(opts),
            "fd=%i,rootmode=40000,default_permissions,allow_other,user_id=%d,group_id=%d",
            fuse->fd, fuse->global->uid, fuse->global->gid);
    if (mount("/dev/fuse", fuse->dest_path, "fuse", MS_NOSUID | MS_NODEV | MS_NOEXEC |
            MS_NOATIME, opts) != 0) {
        ERROR("failed to mount fuse filesystem: %s\n", strerror(errno));
        return -1;
    }

    fuse->gid = gid;
    fuse->mask = mask;

    return 0;
}

static void run(const char* source_path, const char* label, uid_t uid,
        gid_t gid, userid_t userid, bool multi_user, bool full_write) {
    struct fuse_global global;
    struct fuse fuse_default;
    struct fuse fuse_read;
    struct fuse fuse_write;
    struct fuse_handler handler_default;
    struct fuse_handler handler_read;
    struct fuse_handler handler_write;
    pthread_t thread_default;
    pthread_t thread_read;
    pthread_t thread_write;

    memset(&global, 0, sizeof(global));
    memset(&fuse_default, 0, sizeof(fuse_default));
    memset(&fuse_read, 0, sizeof(fuse_read));
    memset(&fuse_write, 0, sizeof(fuse_write));
    memset(&handler_default, 0, sizeof(handler_default));
    memset(&handler_read, 0, sizeof(handler_read));
    memset(&handler_write, 0, sizeof(handler_write));

    pthread_mutex_init(&global.lock, NULL);
    global.package_to_appid = hashmapCreate(256, str_hash, str_icase_equals);
    global.uid = uid;
    global.gid = gid;
    global.multi_user = multi_user;
    global.next_generation = 0;
    global.inode_ctr = 1;

    memset(&global.root, 0, sizeof(global.root));
    global.root.nid = FUSE_ROOT_ID; /* 1 */
    global.root.refcount = 2;
    global.root.namelen = strlen(source_path);
    global.root.name = strdup(source_path);
    global.root.userid = userid;
    global.root.uid = AID_ROOT;
    global.root.under_android = false;

    strcpy(global.source_path, source_path);

    if (multi_user) {
        global.root.perm = PERM_PRE_ROOT;
        snprintf(global.obb_path, sizeof(global.obb_path), "%s/obb", source_path);
    } else {
        global.root.perm = PERM_ROOT;
        snprintf(global.obb_path, sizeof(global.obb_path), "%s/Android/obb", source_path);
    }

    fuse_default.global = &global;
    fuse_read.global = &global;
    fuse_write.global = &global;

    global.fuse_default = &fuse_default;
    global.fuse_read = &fuse_read;
    global.fuse_write = &fuse_write;

    snprintf(fuse_default.dest_path, PATH_MAX, "/mnt/runtime/default/%s", label);
    snprintf(fuse_read.dest_path, PATH_MAX, "/mnt/runtime/read/%s", label);
    snprintf(fuse_write.dest_path, PATH_MAX, "/mnt/runtime/write/%s", label);

    handler_default.fuse = &fuse_default;
    handler_read.fuse = &fuse_read;
    handler_write.fuse = &fuse_write;

    handler_default.token = 0;
    handler_read.token = 1;
    handler_write.token = 2;

    umask(0);

    if (multi_user) {
        /* Multi-user storage is fully isolated per user, so "other"
         * permissions are completely masked off. */
        if (fuse_setup(&fuse_default, AID_SDCARD_RW, 0006)
                || fuse_setup(&fuse_read, AID_EVERYBODY, 0027)
                || fuse_setup(&fuse_write, AID_EVERYBODY, full_write ? 0007 : 0027)) {
            ERROR("failed to fuse_setup\n");
            exit(1);
        }
    } else {
        /* Physical storage is readable by all users on device, but
         * the Android directories are masked off to a single user
         * deep inside attr_from_stat(). */
        if (fuse_setup(&fuse_default, AID_SDCARD_RW, 0006)
                || fuse_setup(&fuse_read, AID_EVERYBODY, full_write ? 0027 : 0022)
                || fuse_setup(&fuse_write, AID_EVERYBODY, full_write ? 0007 : 0022)) {
            ERROR("failed to fuse_setup\n");
            exit(1);
        }
    }

    /* Drop privs */
    if (setgroups(sizeof(kGroups) / sizeof(kGroups[0]), kGroups) < 0) {
        ERROR("cannot setgroups: %s\n", strerror(errno));
        exit(1);
    }
    if (setgid(gid) < 0) {
        ERROR("cannot setgid: %s\n", strerror(errno));
        exit(1);
    }
    if (setuid(uid) < 0) {
        ERROR("cannot setuid: %s\n", strerror(errno));
        exit(1);
    }

    if (multi_user) {
        fs_prepare_dir(global.obb_path, 0775, uid, gid);
    }

    if (pthread_create(&thread_default, NULL, start_handler, &handler_default)
            || pthread_create(&thread_read, NULL, start_handler, &handler_read)
            || pthread_create(&thread_write, NULL, start_handler, &handler_write)) {
        ERROR("failed to pthread_create\n");
        exit(1);
    }

    watch_package_list(&global);
    ERROR("terminated prematurely\n");
    exit(1);
}
```

sdcard service 是 fuse 的守护进程，在 4.0 以后的 android 版本上，sdcard 都是通过 sdcard 服务来挂载和访问的，而且该服务程序还提供额外的权限控制。

上述代码是 sdcard 的挂载部分，关键代码即根据 vold 传过来的参数来准备好 uid/gid/userid 等信息，并且根据是否为多用户 ( multi_user )，是否 full_write 来准备好下面三个目录的用户组及其对应的权限：

* /mnt/runtime/default/emulated
* /mnt/runtime/read/emulated
* /mnt/runtime/write/emulated

#### Step 2: 三视图

在第一步结束后，所有挂载的存储设备都会维护三个不同视图：

* **/mnt/runtime/default** - 对所有的应用、root 命名空间（adb 和其他系统组件）可见，而无需任何权限
* **/mnt/runtime/read** - 对有 `READ_EXTERNAL_STORAGE` 权限的应用可见。
* **/mnt/runtime/write** - 对有 `WRITE_EXTERNAL_STORAGE` 权限的应用可见。

> 为什么这样，请一直看到文章结尾，自然知晓原理。

```
root@bullhead:/mnt/runtime/default/emulated # ls -l
drwxrwx--x root     sdcard_rw          1970-03-04 02:51 0
drwxrwx--x root     sdcard_rw          1970-03-04 02:51 obb

root@bullhead:/mnt/runtime/read/emulated # ls -l
drwxr-x--- root     everybody          1970-03-04 02:51 0
drwxr-x--- root     everybody          1970-03-04 02:51 obb

root@bullhead:/mnt/runtime/write/emulated # ls -l
drwxrwx--- root     everybody          1970-03-04 02:51 0
drwxrwx--- root     everybody          1970-03-04 02:51 obb
```

上述 **default/read/write** 三个目录下的 **0** 和 **obb** 目录所赋予的用户组和权限各不相同。
这将为后面不同应用程序的运行时权限打下了基础。

> 注意，这里的 0 代表用户 0 , 这里需要特别说明一下，从 4.0 后 android 也同时逐步引入了多用户的支持。

#### Step 3: 应用程序启动授权

在 zygote fork app 时，我们为每个运行中的应用创建一个 mount 名字空间，并在其中 bind mount 合适的初始视图。

```java
// Create a private mount namespace and bind mount appropriate emulated
// storage for the given user.
static bool MountEmulatedStorage(uid_t uid, jint mount_mode,
        bool force_mount_namespace) {
    // See storage config details at http://source.android.com/tech/storage/

    // Create a second private mount namespace for our process
    if (unshare(CLONE_NEWNS) == -1) {
        ALOGW("Failed to unshare(): %s", strerror(errno));
        return false;
    }

    // Unmount storage provided by root namespace and mount requested view
    UnmountTree("/storage");

    String8 storageSource;
    if (mount_mode == MOUNT_EXTERNAL_DEFAULT) {
        storageSource = "/mnt/runtime/default";
    } else if (mount_mode == MOUNT_EXTERNAL_READ) {
        storageSource = "/mnt/runtime/read";
    } else if (mount_mode == MOUNT_EXTERNAL_WRITE) {
        storageSource = "/mnt/runtime/write";
    } else {
        // Sane default of no storage visible
        return true;
    }
    if (TEMP_FAILURE_RETRY(mount(storageSource.string(), "/storage",
            NULL, MS_BIND | MS_REC | MS_SLAVE, NULL)) == -1) {
        ALOGW("Failed to mount %s to /storage: %s", storageSource.string(), strerror(errno));
        return false;
    }

    // Mount user-specific symlink helper into place
    userid_t user_id = multiuser_get_user_id(uid);
    const String8 userSource(String8::format("/mnt/user/%d", user_id));
    if (fs_prepare_dir(userSource.string(), 0751, 0, 0) == -1) {
        return false;
    }
    if (TEMP_FAILURE_RETRY(mount(userSource.string(), "/storage/self",
            NULL, MS_BIND, NULL)) == -1) {
        ALOGW("Failed to mount %s to /storage/self: %s", userSource.string(), strerror(errno));
        return false;
    }

    return true;
}
```

我们仔细的分析这段代码做了些什么：

1. 根据 mount mode 从上面三个已经准备好的路径中选择一个默认的挂载路径，并将这个路径挂到 `/storage` 上去。注意：这里带的是 `MS_BIND | MS_REC | MS_SLAVE` 参数，这意味着会拷贝命名空间，所以，每个 app 进入的 `/storage` 都是私有的。

2. 再根据当前的 user_id ，将 `/mnt/user/user_id` bind 到当前 `/storage` 的 self 目录上。

**经过上述两步之后，达到了一个什么目的呢？**

***每个 app 都根据自己的授权，选择了不同权限的 runtime 目录进行访问，而不同用户访问的目录也跟去当前用户的 id 区分开了。***

> 一切都完美的工作起来了，好像可以结束了！

#### Step 4: 应用程序 runtime 授权

> 回到我们文章开头介绍的 runtime 权限，我们发现，到目前为止，我们似乎并不能 runtime 控制权限？那我们要如何做呢？

其实方法特别简单，当被授予运行时权限时，vold 在运行中的应用的名字空间上，通过 bind mount 来更新视图。

* 我猜测 runtime 授权的入口代码是这个：
	*/frameworks/base/services/core/java/com/android/server/pm/PermissionsState.java*

```java
grantRuntimePermission
  -> onExternalStoragePolicyChanged
    -->remountUidExternalStorage
    mConnector.execute("volume", "remount_uid", uid, modeName);
```

* 然后 */system/vold/CommandListener.cpp*

```java
CommandListener::VolumeCmd::runCommand
  ->sendGenericOkFail(cli, vm->remountUid(uid, mode));
```

* 重点 */system/vold/VolumeManager.cpp*

```java
int VolumeManager::remountUid(uid_t uid, const std::string& mode) {
    LOG(DEBUG) << "Remounting " << uid << " as mode " << mode;

    DIR* dir;
    struct dirent* de;
    char rootName[PATH_MAX];
    char pidName[PATH_MAX];
    int pidFd;
    int nsFd;
    struct stat sb;
    pid_t child;

    if (!(dir = opendir("/proc"))) {
        PLOG(ERROR) << "Failed to opendir";
        return -1;
    }

    // Figure out root namespace to compare against below
    if (sane_readlinkat(dirfd(dir), "1/ns/mnt", rootName, PATH_MAX) == -1) {
        PLOG(ERROR) << "Failed to readlink";
        closedir(dir);
        return -1;
    }

    // Poke through all running PIDs look for apps running as UID
    while ((de = readdir(dir))) {
        pidFd = -1;
        nsFd = -1;

        pidFd = openat(dirfd(dir), de->d_name, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        if (pidFd < 0) {
            goto next;
        }
        if (fstat(pidFd, &sb) != 0) {
            PLOG(WARNING) << "Failed to stat " << de->d_name;
            goto next;
        }
        if (sb.st_uid != uid) {
            goto next;
        }

        // Matches so far, but refuse to touch if in root namespace
        LOG(DEBUG) << "Found matching PID " << de->d_name;
        if (sane_readlinkat(pidFd, "ns/mnt", pidName, PATH_MAX) == -1) {
            PLOG(WARNING) << "Failed to read namespace for " << de->d_name;
            goto next;
        }
        if (!strcmp(rootName, pidName)) {
            LOG(WARNING) << "Skipping due to root namespace";
            goto next;
        }

        // We purposefully leave the namespace open across the fork
        nsFd = openat(pidFd, "ns/mnt", O_RDONLY);
        if (nsFd < 0) {
            PLOG(WARNING) << "Failed to open namespace for " << de->d_name;
            goto next;
        }

        if (!(child = fork())) {
            if (setns(nsFd, CLONE_NEWNS) != 0) {
                PLOG(ERROR) << "Failed to setns for " << de->d_name;
                _exit(1);
            }

            unmount_tree("/storage");

            std::string storageSource;
            if (mode == "default") {
                storageSource = "/mnt/runtime/default";
            } else if (mode == "read") {
                storageSource = "/mnt/runtime/read";
            } else if (mode == "write") {
                storageSource = "/mnt/runtime/write";
            } else {
                // Sane default of no storage visible
                _exit(0);
            }
            if (TEMP_FAILURE_RETRY(mount(storageSource.c_str(), "/storage",
                    NULL, MS_BIND | MS_REC | MS_SLAVE, NULL)) == -1) {
                PLOG(ERROR) << "Failed to mount " << storageSource << " for "
                        << de->d_name;
                _exit(1);
            }

            // Mount user-specific symlink helper into place
            userid_t user_id = multiuser_get_user_id(uid);
            std::string userSource(StringPrintf("/mnt/user/%d", user_id));
            if (TEMP_FAILURE_RETRY(mount(userSource.c_str(), "/storage/self",
                    NULL, MS_BIND, NULL)) == -1) {
                PLOG(ERROR) << "Failed to mount " << userSource << " for "
                        << de->d_name;
                _exit(1);
            }

            _exit(0);
        }

        if (child == -1) {
            PLOG(ERROR) << "Failed to fork";
            goto next;
        } else {
            TEMP_FAILURE_RETRY(waitpid(child, nullptr, 0));
        }

next:
        close(nsFd);
        close(pidFd)
    }
    closedir(dir);
    return 0;
}
```

上述核心代码和 zygote 中很类似，不再赘述，至此，才算彻底搞清楚了 Androd M 在外置存储上权限控制的改变和多用户多进程下的安全原理。

> 系统使用 `setns()` 函数来实现上述特性，这要求 Linux 3.8 , 不过 Linux 3.4 加上补丁上也可以支持该功能。

