# Readest 自托管客户端

本仓库是 [Readest](https://github.com/readest/readest) 的自托管客户端打包仓库，用来发布可以连接到你自己部署的 Readest/Supabase 后端的桌面端和 Android 客户端。

默认说明请看英文 README：[README.md](../README.md)。

## 快速入口

- 下载客户端：[Releases](https://github.com/luoji12103/readest-self-hosted/releases)
- 服务端自托管教程：[docker/README.md](../docker/README.md)
- 客户端连接自托管服务器说明：[docs/selfhost-client.md](./selfhost-client.md)

## 客户端怎么改服务器地址

在已安装客户端中打开登录页或 `Settings -> Server`，填写你的服务器根地址，例如：

```text
https://readest.example.com
```

然后点击 `Test connection`，通过后点击 `Save`。不要在地址后面加 `/api`，客户端会自动拼接 API 路径。

切换服务器会清除当前登录状态，需要重新登录。
