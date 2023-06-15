---
layout: post
title: "Android 中的设计模式 —— 单例模式"
keywords: ["Android", "Framework", "设计模式"]
categories: "程序设计"
tags: ["Android", "Framework", "设计模式", "Singleton"]
author: Zhang Xing
permalink: ./android-design-pattern-singleton.html
---

## 设计模式简介

当我们讨论设计模式的时候，其实我们在讨论面向对象的设计问题。

软件设计中很多问题都会一次又一次的重复出现，而经过一定的总结之后会有一些优秀的解法沉淀下来，可以用于以后出现的类似问题，我们把这些解法叫做设计模式。

软件的生命周期决定了其设计要尽可能地面对（需求）改变，所以在开发和维护过程中，面临的较大问题，除了解决问题的关键点，另一个就是解决需求变更和扩展所带来的代码结构变化问题。而设计模式刚好可以让我们的设计更加灵活，在解决问题的基础上，也使得后期的功能扩展对原有结构的影响尽可能小。

**推荐书籍：**

1. [ 设计模式：可复用面向对象软件的基础 ] [ 推荐书籍 1]
2. [Head First 设计模式 ] [ 推荐书籍 2]

[ 推荐书籍 1]: http://item.jd.com/10057319.html ' 设计模式：可复用面向对象软件的基础 '

[ 推荐书籍 2]: http://item.jd.com/10100236.html 'Head First 设计模式 '

## 面向对象软件设计原则

[《Head First 设计模式》] [ 推荐书籍 2] 一书里面提炼了很多 OO 设计的原则，在这里分析其中的一些。

1. **找出需求中“可能变化”之处，把它们独立出来。** 这样，新需求对原架构的影响就会减小很多。这个是程序设计最基本的原则，也可以说成，让每次的变化，尽可能地影响最少的代码。
2. **针对接口编程，而不是针对实现编程。** 这里的接口，可以是 Interface，也可以是 base class，最关键的是，当行为改变时，对使用该接口的地方来讲是透明的。也就是说，要有效利用多态的特性。
3. **多用组合、少用继承。** 为什么要少用继承？个人的理解是，继承都需要用在能表现多态的地方。
4. **为了交互对象之间的松耦合设计而努力。** 这个好像不用解释。
5. **要依赖抽象，不要依赖具体类。** 一旦依赖了具体类，就没办法低耦合了。
6. **一个类只应该有一个引起变化的原因。** 这是我们奋斗的目标，但是有时候需要综合其他的原则一起考虑。

还有一些其他原则，有待在实践中不断深化，这里不一一列举了。

## 设计模式举例

### 单例模式

单例模式应该是最简单的一个模式，因为它不涉及和其他类交互的问题。但是写好单例模式并不容易，特别是在多线程环境下，单例模式有时候并不好写。

当确定系统只需要某个对象的唯一实例时，就需要使用单例模式。

先看看关系图如下：

![ 单例模式 UML 类图 ](http://i.imgur.com/qAjcNLz.jpg)

最简单的写法就是只提供一个 private 的构造方法，一个 static 的对象和获取这个对象的函数，如下所示：

```
public class Singleton{
	 private static Singleton singleton = null;
	 private Singleton(){}
	 public Singleton getInstance(){
		if(singleton == null){
			singleton = new Singleton();
		}
		return singleton;
	 }
}
```

不过这种写法即使是在笔试的时候，也的不了多少分的。

#### 实际应用举例

一个比较过关的写法是考虑多线程的情况下能够正常运行，并且尽可能推迟生成实例（在生成实例代价较大的情况下比较有用）。以下是一个具体的场景：要根据手机屏幕的亮灭来控制手机 LED 灯的亮灭，这样可以在无屏幕的状态下根据 LED 的情况判断手机是否处于开机状态。

因为 Framework 中 `DisplayPowerState` 这个类有在 `PowerManagerService` 里面更新屏幕的状态，如果不用单例模式，会出现生成多个控制 LED 灯的对象，导致 LED 在指定状态下是一闪一闪的状态，无法达到指定需求。所以考虑使用单例模式来写 LED 对象。

```
private static class LightHandler extends Handler{
	private static final Object mLock = new Object();
	private volatile static LightHandler mlightHandler = null;
	private LightHandler(){
		super();
	}
	private LightHandler(Looper looper){
		super(looper);
	}
	public static LightHandler getInstance(Looper looper){
		if(mlightHandler == null){
			synchronized(mLock){
				if(mlightHandler == null)
					mlightHandler = new LightHandler(looper);
				}
		}
		return mlightHandler;
	}
	...
}
```

考虑目前的 Android 版本使用的 java 都在 1.6 以上，所以 `volatile` 关键字可以有效使用。实测该方法可以有效控制 LED 灯不再闪烁。

#### Framework 层代码使用单例模式的例子

github 上有一个很完整的例子：[Framework 中的单例模式](https://github.com/simple-Android-framework/android_design_patterns_analysis/tree/master/singleton/mr.simple "Framework 中的单例模式 ")

这个例子里面解释了 `LayoutInflater` 使用单例的情况，写得非常详细。里面也提到了 Framework 层的很多  Serivce 都是单例模式，那这里就去看看源代码吧。

`.frameworks/base/core/java/com/Android/server/LocalServices.java` 这个文件就是典型的例子。

```
import android.util.ArrayMap;

public final class LocalServices {
	private LocalServices() {}
	private static final ArrayMap<Class<?>, Object> sLocalServiceObjects =
		new ArrayMap<Class<?>, Object>();

	@SuppressWarnings("unchecked")
	public static <T> T getService(Class<T> type) {
		synchronized (sLocalServiceObjects) {
			return (T) sLocalServiceObjects.get(type);
		}
	}

	public static <T> void addService(Class<T> type, T service) {
		synchronized (sLocalServiceObjects) {
			if (sLocalServiceObjects.containsKey(type)) {
				throw new IllegalStateException("Overriding service registration");
			}
			sLocalServiceObjects.put(type, service);
		}
	}
}
```

每次添加 Service 的时候，都是往 `ArrayMap` 里面添加一个 `key-value` 对，通过控制这个数据结构来达到单例的要求。所有的 `LoacalServices` 在系统中都保持只有一个实例，需要用到的时候，使用 `getService()` 函数获取即可。可以看到以下一些使用的例子：

```
./services/core/java/com/android/server/VibratorService.java:230:	 mPowerManagerInternal = LocalServices.getService(PowerManagerInternal.class);
./services/core/java/com/android/server/power/Notifier.java:141:	mActivityManagerInternal = LocalServices.getService(ActivityManagerInternal.class);
./services/core/java/com/android/server/SystemService.java:197:        return LocalServices.getService(SystemServiceManager.class);
```

这些都是需要使用 `LoacalServices` 的例子。

