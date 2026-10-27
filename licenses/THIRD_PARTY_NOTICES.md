# 第三方组件与来源

本目录中的上游许可适用于对应第三方组件。本应用自身的页面、规则和断语适配模型不因随附第三方许可而自动获得新的许可授权。

| 组件 | 来源与版本 | 随附许可 |
|---|---|---|
| Windows x64 Vulkan/CPU 推理程序 | [llama.cpp](https://github.com/ggml-org/llama.cpp/tree/f5919bf45)，b10227 / f5919bf45；本包固定 SHA256 见清单 | `llama.cpp-LICENSE.txt`，MIT |
| OpenMP 运行库 | 推理压缩包内的 `libomp140.x86_64.dll`；LLVM 20.1.8 对应许可 | `LLVM-LICENSE.txt`，Apache 2.0 with LLVM Exceptions |
| 基础语言模型 | [Qwen2.5-7B-Instruct-GGUF](https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF)，Q4_K_M；从 Qwen 官方仓库下载，不随 Git 分发 | `Qwen2.5-LICENSE.txt`，Apache 2.0 |
| 网页运行依赖 | React、React Router、GSAP、Framer Motion、Radix UI、Lucide 等，版本由原构建锁文件固定 | `frontend-LICENSES.md` |

微软 Visual C++ Redistributable 在需要时从 [微软官方地址](https://aka.ms/vs/17/release/vc_redist.x64.exe) 下载，按其安装程序许可使用。

项目断语 LoRA 随运行包提供，必须搭配清单中指定的 Qwen 基础模型使用。基础模型权利与限制仍按上游许可执行。

2026-10-27 发布适配：网页路由改为哈希地址、API 改为同源调用、移除远程字体链接；推理程序与适配模型文件保持原字节。
