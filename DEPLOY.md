# 用 GitHub Pages 发布教程（分步说明）

你的教程在 `**docs/**` 里；根目录的 `**docs/index.html**` 会跳到 `uxcam-product-analytics-tutorial.html`，所以 GitHub Pages 选择「从 `**/docs**` 文件夹发布」即可。

下面按顺序做即可。把文中的 `**<你的用户名>**`、`**<仓库名>**` 换成你自己的（例如 `lishuang` / `uxcam-tutorial`）。

---

## 第 1 步：在 GitHub 上新建空仓库

1. 浏览器打开 [https://github.com/new](https://github.com/new)。
2. **Repository name** 填一个名字，例如：`uxcam-tutorial`（记下这个名字，下面叫 `**<仓库名>`**）。
3. 选 **Public**（免费 Pages 对公开库最省事）。
4. **不要**勾选「Add a README」等任何初始化文件（保持仓库是空的，方便第一次推送）。
5. 点 **Create repository**。
6. 创建完成后，页面上会有一串地址，形如：
  `https://github.com/<你的用户名>/<仓库名>.git`  
   复制备用（下面叫 **仓库地址**）。

---

## 第 2 步：在本机项目里初始化 Git 并提交（若已做过可跳过）

在终端进入本项目根目录（含 `docs` 文件夹的那一层），执行：

```bash
git init
git add .
git commit -m "Add UXCam tutorial static site for GitHub Pages"
git branch -M main
```

若提示需要配置用户名邮箱（第一次在本机用 Git）：

```bash
git config user.email "你的邮箱@example.com"
git config user.name "你的名字"
```

再执行一次 `git commit`（若上一步已失败则从头 `git add` + `git commit`）。

---

## 第 3 步：关联远程并推送

把下面的 **仓库地址** 换成你在第 1 步复制的 `https://github.com/...git`：

```bash
git remote add origin <仓库地址>
git push -u origin main
```

- 若 GitHub 已要求用 **HTTPS + Token** 或 **SSH**，按你平时推送其它仓库的方式登录即可。  
- 若提示 `remote origin already exists`，先执行：  
`git remote remove origin`  
再重新 `git remote add origin ...`。

推送成功后，在 GitHub 网页上刷新仓库，应能看到 `docs/`、`DEPLOY.md` 等文件。

---

## 第 4 步：打开 GitHub Pages

1. 打开你的仓库页面：`https://github.com/<你的用户名>/<仓库名>`。
2. 点 **Settings**（设置）。
3. 左侧点 **Pages**（在「Code and automation」里）。
4. **Build and deployment** 里：
  - **Source** 选：**Deploy from a branch**。
  - **Branch**：选 `**main`**，文件夹选 `**/docs`**（不是 root）。
5. 点 **Save**。

---

## 第 5 步：等站点生效并访问

- 等 **1～3 分钟**（有时更久）。同一 Pages 页面顶部可能出现绿色提示条，里面会有站点地址。
- 一般访问格式为：  
`**https://<你的用户名>.github.io/<仓库名>/`**  
打开后应自动进入教程页（经 `docs/index.html` 跳转）。

若 404：再等几分钟；确认 Branch 是 `**main`** 且目录是 `**/docs`**；看 **Actions** 里是否有报错（纯静态 `/docs` 通常没有 Action，以 Settings → Pages 提示为准）。

---

## 以后更新教程

改完 `docs/uxcam-product-analytics-tutorial.html`（或其它文件）后：

```bash
git add .
git commit -m "更新教程内容"
git push
```

几分钟后网页会自动更新。

---

## 本地预览（可选）

```bash
npx --yes serve docs -p 3456
```

浏览器访问：`http://localhost:3456`