#include <am.h>
#include <klib-macros.h>
#include <klib.h>

void __am_timer_init();
void __am_gpu_init();
void __am_audio_init();
void __am_input_keybrd(AM_INPUT_KEYBRD_T *);
void __am_timer_rtc(AM_TIMER_RTC_T *);
void __am_timer_uptime(AM_TIMER_UPTIME_T *);
void __am_gpu_config(AM_GPU_CONFIG_T *);
void __am_gpu_status(AM_GPU_STATUS_T *);
void __am_gpu_fbdraw(AM_GPU_FBDRAW_T *);
void __am_audio_config(AM_AUDIO_CONFIG_T *);
void __am_audio_ctrl(AM_AUDIO_CTRL_T *);
void __am_audio_status(AM_AUDIO_STATUS_T *);
void __am_audio_play(AM_AUDIO_PLAY_T *);
void __am_disk_config(AM_DISK_CONFIG_T *cfg);
void __am_disk_status(AM_DISK_STATUS_T *stat);
void __am_disk_blkio(AM_DISK_BLKIO_T *io);

static void __am_timer_config(AM_TIMER_CONFIG_T *cfg) { cfg->present = true; cfg->has_rtc = true; }
static void __am_input_config(AM_INPUT_CONFIG_T *cfg) { cfg->present = true;  }
static void __am_uart_config(AM_UART_CONFIG_T *cfg)   { cfg->present = false; }
static void __am_net_config (AM_NET_CONFIG_T *cfg)    { cfg->present = false; }

typedef void (*handler_t)(void *buf);
static void *lut[128] = {
  [AM_TIMER_CONFIG] = __am_timer_config,
  [AM_TIMER_RTC   ] = __am_timer_rtc,
  [AM_TIMER_UPTIME] = __am_timer_uptime,
  [AM_INPUT_CONFIG] = __am_input_config,
  [AM_INPUT_KEYBRD] = __am_input_keybrd,
  [AM_GPU_CONFIG  ] = __am_gpu_config,
  [AM_GPU_FBDRAW  ] = __am_gpu_fbdraw,
  [AM_GPU_STATUS  ] = __am_gpu_status,
  [AM_UART_CONFIG ] = __am_uart_config,
  [AM_AUDIO_CONFIG] = __am_audio_config,
  [AM_AUDIO_CTRL  ] = __am_audio_ctrl,
  [AM_AUDIO_STATUS] = __am_audio_status,
  [AM_AUDIO_PLAY  ] = __am_audio_play,
  [AM_DISK_CONFIG ] = __am_disk_config,
  [AM_DISK_STATUS ] = __am_disk_status,
  [AM_DISK_BLKIO  ] = __am_disk_blkio,
  [AM_NET_CONFIG  ] = __am_net_config,
};

static void fail(void *buf) { panic("access nonexist register"); }

bool ioe_init() {
  for (int i = 0; i < LENGTH(lut); i++)
    if (!lut[i]) lut[i] = fail;
  __am_gpu_init();
  __am_timer_init();
  __am_audio_init();
  return true;
}

void ioe_read (int reg, void *buf) { ((handler_t)lut[reg])(buf); }
void ioe_write(int reg, void *buf) { ((handler_t)lut[reg])(buf); }

/*
//AM程序：
AM程序是直接通过最上层的io_read访问设备寄存器

//klib：对IOE提供的API做了进一步的封装，以便可以更方便地访问
io_read()
io_write()

//IOE：IOE提供的API, AM程序使用这些接口直接读取设备寄存器的信息
//IOE自定了一组抽象设备，然后各自的架构要遵守这个抽象设备的规则
bool ioe_init();
void ioe_read(int reg, void *buf);
void ioe_write(int reg, void *buf);
定义了一组抽象设备，即am_dev, 下面是和时钟相关的设备
AM_DEVREG( 4, TIMER_CONFIG, RD, bool present, has_rtc);
AM_DEVREG( 5, TIMER_RTC,    RD, int year, month, day, hour, minute, second);
AM_DEVREG( 6, TIMER_UPTIME, RD, uint64_t us);


//特别地, NEMU作为一个平台, 设备的行为是与ISA无关的, 
//因此我们只需要在abstract-machine/am/src/platform/nemu/ioe/
NEMU的ioe实现是timer.c, 这些函数要去访问设备
__am_timer_init();
__am_timer_rtc(),
__am_timer_uptime(),

然后在timer.c里面，包含的头文件就只有这些
整个timer.c包含的头文件为  am.h 
                        nemu.h  klib-macros.h riscv.h(架构)
剩下能访问的就是           AM_TIMER_UPTIME 与 AM_TIMER_RTC_T
也就是说想要实现时钟，只有这么多信息

*/
