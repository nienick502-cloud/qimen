# 运行模型

`duanyu-lora-f16.gguf` 是本应用随包提供的断语适配模型。基础模型由启动器自动下载到此目录，首次下载完成后无需重复下载。

基础模型：Qwen/Qwen2.5-7B-Instruct-GGUF，Q4_K_M 官方双分片。精确文件名、大小、SHA256 和下载地址见 `../runtime/manifest.json`。推理程序会自动加载两片。

如果已有本项目原版 `qwen2.5-7b-instruct-q4_k_m.gguf` 单文件，也可以放在此目录；启动器仅在其 SHA256 与清单匹配时直接使用。
