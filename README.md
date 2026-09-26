# 实验室样品检测管理平台

面向第三方检测实验室样品接收、任务分配、检测分析、结果复核、报告签发与标物管理的检测业务管理后台。

这是一个前后端分离的管理平台：前端 Vue 3 + Vite + TypeScript，后端 FastAPI（Python）。
两边各自独立启动，前端 dev server 已关掉自动打开页面，启动后按终端打印的地址手工打开。

## 目录结构

```text
.
├── frontend/                 Vue 3 + Vite + TypeScript 前端
│   ├── src/views/            每个业务模块一个页面
│   ├── src/api/              统一请求封装
│   ├── src/stores/           会话与筛选状态
│   └── vite.config.ts        dev server 配置（open: false）
├── backend/                  FastAPI（Python） 后端
│   ├── app/routers/          每个业务模块一组接口
│   ├── app/services/         业务规则与状态流转
│   └── app/store.py          内存数据仓库与示例数据
├── scripts/                  本地签发链路工程化脚本
│   ├── preflight.sh          依赖 / 端口占用前置检查
│   ├── setup.sh              幂等安装前后端依赖
│   ├── dev-up.sh             一条命令：构建 + 起服务 + 写签发样例 + 检查
│   ├── dev-down.sh           停止本地服务（含端口兜底清理）
│   ├── run_report_flow.py    经接口驱动 待编制→已签发（幂等）
│   ├── verify_report.py      可复现检查：报告结论与接口返回一致
│   └── report-flow.json      签发样例与检查共用的期望值（单一事实来源）
├── Makefile                  make setup / up / down / check 入口
├── .gitignore
└── docker-compose.yml
```

## 启动

### 一条命令跑通签发链路（推荐）

报告的「编制 → 审核 → 签发」要跨前后端联调，不用再手工开两个终端、手工造数据：

```bash
make setup   # 首次：幂等安装前后端依赖（venv 损坏 / 跨平台 node_modules 会自动修复）
make up      # 前置检查 -> 构建前端 -> 拉起前后端 -> 写入签发样例 -> 一致性检查
```

`make up` 会依次完成：

1. **前置检查**：`python3`/`node`/`npm` 是否存在、8000/5173 端口是否空闲、依赖是否就绪，
   不满足时直接报出原因和修复建议（不会带着问题继续往下跑）；
2. **构建前端**：`npm run build`（vue-tsc 类型检查 + vite 构建）；
3. **拉起服务**：后端 uvicorn（:8000）+ 前端 `vite preview` 托管构建产物（:5173，`/api`
   代理到后端）；
4. **写入签发链路样例**：通过真实接口登记 `REPO-FLOW-0001` 并依次执行
   编制报告 → 审核通过 → 签发报告，报告编号、编制人（李晓雯）、审核人（陈建国）、
   签发人（赵宏斌）、报告结论全部落库。后端是内存库，每次重启都会自动补写；
5. **可复现检查**：`make check` 从同一份 `scripts/report-flow.json` 取期望值，
   核对列表 / 详情 / 导出 / 前端代理四处接口返回的报告结论完全一致，PASS 才算启动成功。

启动成功后：

| 用途 | 地址 / 命令 |
| --- | --- |
| 报告页面（构建产物） | http://127.0.0.1:5173/report |
| 后端健康检查 | http://127.0.0.1:8000/api/health |
| 停止服务 | `make down` |
| 不重新构建快速重启 | `make up-fast` |
| 服务运行期间反复核对 | `make check` |
| 只重跑签发样例（幂等） | `make check-flow` |
| 只做启动前检查 | `make preflight` |

运行日志和最终签发记录在 `.run/logs/` 与 `.run/report-issued.json`（已被 git 忽略）。
端口冲突时可临时换端口：`BACKEND_PORT=8010 FRONTEND_PORT=5174 make up`。

签发链路在后端强约束顺序流转，禁止跳段：待编制只能编制、待审核只能审核（必须带审核人）、
待签发才能签发（必须带签发人）；跨段请求会被 `app/services/report.py` 拦下并返回原因。

### 手工分别启动（老习惯仍然保留）

#### 后端

```bash
cd backend
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
./run.sh
```

健康检查：`curl http://127.0.0.1:8000/api/health`

#### 前端

```bash
cd frontend
npm install
npm run dev
```

前端默认监听 `http://127.0.0.1:5173/`，dev server 不会自动打开浏览器，
需要自己访问。`/api` 由 vite 代理到后端 `http://127.0.0.1:8000`。
联调构建产物时改用 `npm run preview`，代理口径与 dev server 一致。

## 业务模块

| 模块 | 目录 | 业务对象 | 主要字段 |
| --- | --- | --- | --- |
| 样品登记 | `sample` | 检测样品 | 样品编号、样品名称、委托单位 |
| 委托合同 | `contract` | 委托合同 | 合同编号、委托单位、检测项目 |
| 检测任务 | `task` | 检测任务 | 任务编号、关联样品、检测项目 |
| 检测方法 | `method` | 检测方法 | 方法编号、方法名称、标准编号 |
| 仪器设备 | `instrument` | 仪器 | 仪器编号、仪器名称、规格型号 |
| 标准物质 | `standard` | 标准物质 | 标物编号、标物名称、证书编号 |
| 检测结果 | `result` | 检测结果 | 结果编号、关联任务、检测项目 |
| 检测报告 | `report` | 检测报告 | 报告编号、关联任务、编制人、审核人、签发人、报告结论 |
| 分包检测 | `boundary` | 分包记录 | 分包编号、分包原因、分包方名称 |
| 不符合项 | `abnormal` | 不符合项 | 不符合编号、发现环节、不符合描述 |
| 环境监控 | `envmonitor` | 环境记录 | 记录编号、监测区域、温度值 |
| 盲样考核 | `blind` | 盲样 | 盲样编号、考核人员、检测项目 |
| 能力验证 | `ability` | 能力验证 | 验证编号、组织方、检测项目 |
| 中间液配制 | `intermediate` | 中间液 | 配制编号、母液编号、目标浓度 |
| 内审检查 | `audit` | 内审记录 | 内审编号、内审日期、内审部门 |
| 认证认可 | `certification` | 资质认定 | 认定编号、认定类型、发证机构 |
| 质控样 | `quality` | 质控样 | 质控样编号、参数名称、标准值 |
| 试剂管理 | `reagent2` | 试剂 | 试剂编号、试剂名称、规格等级 |
| 实验废液 | `waste` | 废液记录 | 废液编号、废液类别、产生环节 |
| 客户反馈 | `opinion` | 反馈记录 | 反馈编号、委托单位、反馈类型 |

## 约定

- 每个模块的前端页面在 `frontend/src/views/<模块>/index.vue`，后端接口在
  `backend/app/routers/<模块>.py`，业务规则在 `backend/app/services/<模块>.py`。
- 列表接口统一返回 `{ items, total, page, size }`，动作接口统一返回 `{ ok, message }`。
- 状态流转只允许在 `app/services` 里改，路由层不做业务判断。
