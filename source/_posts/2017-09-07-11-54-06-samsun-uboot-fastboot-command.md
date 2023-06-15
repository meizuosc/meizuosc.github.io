---
layout: post
title: "samsung uboot fastboot command"
keywords: ["Uboot", "Fastboot"]
description: "fastboot流程和fastboot数据接收"
categories: "Bootloader"
tags: ["fastboot"]
author: Zhang Yaping
permalink: /samsun-uboot-fastboot-command.html
---
## 1 fastboot协议

fastboot 协议是一种通过 usb 连接 pc 和 bootloader 的机制。他被设计的非常容易实现，能够用于多种设备和运行于 Linux、Windows 或者 OSX 的主机。下面将会讲述 pc 和 bootloader 如何通信，以 fastboot flash 命令举例。
	
###  1.1 pc 端

假设烧写的镜像名为 uboot.bin，烧写的分区名为 bootloader。fastboot flash 命令并会被解析为多个命令。
步骤一：pc 发送命令 getvar:partition-type:bootloader
pc 发送的第一个命令，获取分区类型，如果你是某种特殊的类型，如 "ext4"。那么 pc 端会发送擦除这个分区的命令，然后在烧写一个 ext4 的类型的镜像进去。此处要烧写的分区是 bootloader，他没有特殊的格式，那么 uboot 就没有回应。
步骤二：pc 发送命令 getvar:max-download-size
在bootloader 中有一个接受数据的 buffer。这条命令就是获取这个 buffer 的大小。如果 buffer 太小那么 pc 就会把镜像拆分，分段发送。
步骤三：pc 发送命令 download:01fbe8b2
给出这条命令的时候就是告诉 bootloader，我（pc）现在要发送数据了。接着就是数据的传输过程了。download 命令后面的数据表示发送的数据的大小。
步骤四：pc 发送命令 flash:bootloader
告诉 bootloader 将发送的数据写到 bootloader 分区中去。如果在写数据的时候发现分区大小比数据大小要小，那么此时就会报错。
	
### 1.2 bootloader 的回应

bootloader 是被动响应 pc 发送过来的指令。它给 pc 回应信息是一个不大于 64 个字节的包响应， 响应包开头四个字节是 “OKAY”、“FAIL”、“DATA” 或者 “INFO”。
		a.INFO：表示信心应该被显示
		b.FAIL ：表示命令执行失败
		c.OKAY：表示命令执行成功
		d.DATA：表示请求的命令已经为数据阶段做好准备
对于 pc 端发送过来的命令，bootloader 都会发送响应消息。响应消息的头部就是上述4个中的一个，具体用哪个是具体情况而定。
	
## 2 fastboot 命令

github 上的 uboot 源码中是没有实现 fastboot 的。这部分是由芯片厂商提供的。此处说的是三星在 uboot 中实现的 fastboot 命令。命令的入口函数为 do_fastboot。因为 usb 设备方面的初始化由芯片厂商完成，所以 usb初始化部分将不是本次讨论的重点。我们将重点关注 fastboot 的流程和其 download 机制。
	
### 2.1 fastboot 的 main loop

````
	do
	{
		continue_from_disconnect = 0;

		/* Initialize the board specific support */
		if (0 == fastboot_init(&interface))
		{
			int poll_status, board_poll_status;

			/* If we got this far, we are a success */
			ret = 0;

			timeout_endtime = get_ticks();
			timeout_endtime += timeout_ticks;

			LCD_turnon();

			while (1)
			{
				uint64_t current_time = 0;
				poll_status = fastboot_poll();

				if (1 == check_timeout)
					current_time = get_ticks();

				/* Check if the user wanted to terminate with ^C */
				if ( ((poll_status != FASTBOOT_OK) && (ctrlc())) || gflag_reboot)
				{
					printf("Fastboot ended by user\n");
					continue_from_disconnect = 0;
					break;
				}

				if (FASTBOOT_ERROR == poll_status)
				{
					/* Error */
					printf("Fastboot error \n");
					break;
				}
				else if (FASTBOOT_DISCONNECT == poll_status)
				{
					/* break, cleanup and re-init */
					printf("Fastboot disconnect detected\n");
					continue_from_disconnect = 1;
					break;
				}
				else if ((1 == check_timeout) &&
					   (FASTBOOT_INACTIVE == poll_status))
				{	
					/* No activity */
					if (current_time >= timeout_endtime)
					{
						printf("Fastboot inactivity detected\n");
						break;
					}
				}
				else
				{
					/* Something happened */
					/* Actual works of parsing are done by rx_handler */
					if (1 == check_timeout)
					{
						/* Update the timeout endtime */
						timeout_endtime = current_time;
						timeout_endtime += timeout_ticks;
					}
				}

				board_poll_status = board_fastboot_poll();
				if (BOARD_FASTBOOT_DISCONNECT == board_poll_status)
				{
					printf("Fastboot disconnect detected by board action\n");
					continue_from_disconnect = 0;
					break;
				}
			} /* while (1) */
		}

		/* Reset the board specific support */
		fastboot_shutdown();

		LCD_setfgcolor(0x000010);
		LCD_setleftcolor(0x000010);
		LCD_setprogress(100);

		/* restart the loop if a disconnect was detected */
	} while (continue_from_disconnect);
````
上面是 do_fastboot() 函数的主体部分。当调用 do_fastbboot() 函数时给出了第三个参数时候，那么这个值将被解析为超时时间，但是一般都没有传入第三个参数，所以关于超时的检测可以自动屏蔽了。fastboot_init() 函数，完成 usb 硬件设备相关的的初始化。设置了 serial number 以及接受数据的 buffer 的大小。此处的 buffer 和在 rx_handler() 中提及的 buffer 不同。

while(1) 循环是一直在运行的，除非是检测到了 ctrl+c。通过检测某个中断位是否置 1，判断 pc 是否有消息发送过来，若是有命令发送过来那么将执行 rx_handler() 函数。这个功能是通过函数 fastboot_poll() 函数来实现的。
	
### 2.2 rx_handler()

这个函数有两个参数，第一个参数 const unsigned char *buffer 表示接收到的数据在内存中的地址,第二个参数 unsigned int buffer_size 表示接收到的数据大小。 从这个函数的结构来看，它起初并不知道传进来的是命令还是数据，所以命令和数据都是通过一个 buffer 来接受的。那么他是如何实现下载这项功能的呢？
	
#### 2.2.1 数据下载

在前面说过 pc 端在发送数据之前先发送了 download:01fbe8b2 命令，后面接的是即将发送的数据的大小。  rx_handler() 函数会去处理 download 命令，将即将接收的数据大小放在静态变量 download_size 中。 download 命令处理完成，rx_handler() 函数返回。pc 端开始发送数据，buffer 填充满了之后再调用 rx_handler()函数，此时 download_size 的值不为 0，那么就代表此时接收到的是数据。
````
	if (download_size)
	{
		/* Something to download */

		if (buffer_size)
		{
			/* Handle possible overflow */
			unsigned int transfer_size = download_size - download_bytes;

			if (buffer_size < transfer_size)
				transfer_size = buffer_size;

			/* Save the data to the transfer buffer */
			memcpy (interface.transfer_buffer + download_bytes,
				buffer, transfer_size);

			download_bytes += transfer_size;

			/* Check if transfer is done */
			if (download_bytes >= download_size)
			{
				/* Reset global transfer variable, Keep download_bytes because it will be used in the next possible flashing command */
				download_size = 0;

				if (download_error)
				{
					/* There was an earlier error */
					sprintf(response, "ERROR");
				}
				else
				{
					/* Everything has transferred,
					   send the OK response */
					sprintf(response, "OKAY");
				}
				fastboot_tx_status(response, strlen(response), FASTBOOT_TX_ASYNC);

				printf("\ndownloading of %d bytes finished\n", download_bytes);
				LCD_setprogress(0);

#if defined(CONFIG_RAMDUMP_MODE)
				if (is_ramdump) {
					is_ramdump = 0;
					start_ramdump((void *)buffer);
				}
#endif
			}

			/* Provide some feedback */
			if (download_bytes && download_size && 0 == (download_bytes & (0x100000 - 1)))
			{
				/* Some feeback that the download is happening */
				if (download_error)
					printf("X");
				else
					printf(".");
				if (0 == (download_bytes % (80 * 0x100000))) printf("\n");

				LCD_setfgcolor(0x2E8B57);
				LCD_setprogress(download_bytes / (download_size/100));
			}
		}
		else
		{
			/* Ignore empty buffers */
			printf("Warning empty download buffer\n");
			printf("Ignoring\n");
		}
		ret = 0;
	}
````
上面是 fastboot 下载数据代码的一部分，其中 download_bytes 表示已经接收的数据的大小。当 download_bytes 大于或等于 download_size 表示数据接收完成，此时将 download_size 置为0，那么就退出了数据接收模式。因为接收数据和接收命令使用的是同一个 buffer，导致buffer不可能太大，所以在接收比较大的image的时候就比较慢，例如刷入system.img。通过修改 buffer 的大小或者在 download 命令中完成数据的接收工作，如此就可以解决这个问题。