1.安装emacs
debian/ubuntu下安装:
2snap install --classic emacs或者apt install emacs
或者
http://ftp.gnu.org/pub/gnu/emacs/
下载
windows下安装
http://ftp.gnu.org/pub/gnu/emacs/windows下载,zip和exe包都可以

2.emacsd.tar.xz在家目录下解压。
linux在用户家目录~下解压。
windows下在emacs的安装目录下解压，运行.emacs.d的genemacs_reg.bat生成emacs.reg.双击执行emacs.reg导入注册表完成。
如果不想写注册表。默认windws下的家目录是用户目录/AppData/Roaming比如c:/Users/Administrator/AppData/Roaming。需要emacsd.tar.xz解压到这里。
建议用写注册表方法。windows上需要安装git的windows版本，从https://git-scm.com/下载安装。

3.启动emacs
linux下执行emacs, windows执行安装目录bin/runemacs。

4.启动后菜单栏里多了myhelp, projmenu菜单。projmenu菜单可以选择切换project，建立打开菜单，修改菜单，readlod菜单，或者加载默认菜单。
创建菜单会将默认菜单写到工程目录的.menu.org。修改这个菜单可以增减菜单项目，完成各种功能。默认菜单里包含了loongson-debugger和gdb的调用方法。.menu.org兼容org语法, 每个title是一个菜单，多级title是多级菜单。

5.windows下编译环境
windows下编译环境需要安装msys2.
win7, win8 机器安装msys2 20240113.tar.xz(https://github.com/msys2/msys2-installer/releases?page=2#release-2024-01-13),
win10, win11可以安装最新msys2版本(https://repo.msys2.org/distrib/x86_64)。
启动msys2后运行
pacman -S msys2/gcc
pacman -S msys2/make
这样最基本的编译环境就可以了。其他就是将龙芯的windows工具链解压，加入路径即可。

6. ai支持
 gptel命令和ai聊天。默认配置采用modelscope.cn，在modelscope.cn注册帐号绑定aliyun帐号。从令牌处得到ms-开头的令牌.
设置环境变量set MODELSCOPE_API_KEY ms-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
或者在~/.myemacs里增加。
(setenv "MODELSCOPE_API_KEY" "ms-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx")
再次启动emacs就可以gptel和ai聊天了。
注册modelscope.cn方法: https://modelscope.cn/register

7. emacs新增快捷键
c-z和c-x j快捷键相同
c-x z evil mode和emacs mode切换
c-z z suspend
c-z x 执行emacs命令
c-z : 执行emacs函数
c-z c-z 跳到当前变量函数定义
c-]  跳到当前变量函数定义
c-g 取消
等等

8. emacs作为loongson-debugger前端
ubuntu下拷贝loongson-debugger/scripts/udev/90-jtag.rules到/etc/udev/rules.d/目录下。这样普通用户能访问loongson-debugger的usb设备。
菜单debugger选择set debugger tool选择loongson-debugger的可执行程序,loongarch64处理器是la_dbg_tool_usb, loongarch32处理器是la32_dbg_tool_usb, mips处理器是ejtag_debug_usb.
菜单debugger选择start debugger server开启debugger服务。
然后从debugger里选择对应的命令，或者选择debugger client，在debugger client的telnet端执行多个debugger命令
如果是验证loongson debugger安装执行是否有问题，不启动debugger服务，直接选择debugger菜单/start debugger启动loongson-debugger的命令行接口。

