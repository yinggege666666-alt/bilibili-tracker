# B站数据看板（云端版）

这个文件夹可以发布到 GitHub，让数据每小时在 GitHub 云端自动更新，并生成一个公开网页。发布之后，这台电脑关机、断网都不影响数据更新，其他电脑也能直接打开网页查看。

## 包含内容

- `index.html`：看板网页
- `track.ps1`：每小时抓取B站数据的脚本
- `videos.txt`：视频列表
- `snapshots.csv`：已有的历史快照
- `data.json`：已有的看板数据
- `.github/workflows/update-bilibili.yml`：每小时自动更新任务

## 发布步骤

1. 打开 https://github.com/new 创建一个新仓库
   - 仓库名字随意，例如 `bilibili-tracker`
   - Visibility 选择 Public
   - 不要勾选 README、.gitignore 等初始化选项
   - 点击 Create repository
2. 把本文件夹里的所有内容上传到仓库根目录，包括 `.github` 文件夹
   - 如果网页上传不方便上传隐藏文件夹，可以用 GitHub Desktop，或让另一个 Codex 帮你完成发布
3. 在仓库页面进入 Settings → Pages
   - Source 选择 Deploy from a branch
   - Branch 选择 main，目录选择 / (root)
   - 点击 Save
4. 回到仓库的 Actions 页面，等第一次任务运行完成
5. 打开看板网址：
   `https://你的用户名.github.io/bilibili-tracker/`

以后每小时的 05 分左右会自动抓取一次数据，并更新网页。

## 注意

- 如果第一次打开网页显示“暂无数据”，等第一次 Actions 任务完成后刷新即可
- 每小时自动更新需要 GitHub 免费额度，个人使用完全足够
- 不要删除 `snapshots.csv` 和 `data.json`，它们是历史数据
