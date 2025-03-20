

1、符号化前，将app所有的.dSYM文件和.ips的crash文件，都放在一个目标文件夹下。
目标文件夹结构示例：
    .
    ├── BytedFaceVerifySdk.framework.dSYM
    ├── BBQ-2025-03-19-172118.ips
    ├── BBQ.app.dSYM
    ├── BBQAppClip.app.dSYM
    ├── BBQPushService.appex.dSYM
    └── BBQWidgetExtension.appex.dSYM

2、然后执行命令:`crashDecoder -folder 目标文件夹`  或者 :`crashDecoder 目标文件夹`

3、就可以在目标文件夹中自动将 .ips 解析成 .crash文件

4、支持同时将目标文件夹中的多个 .ips 和多个 .dSYM同时解析
