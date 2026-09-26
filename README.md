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
├── scripts/                  本地一键联调（dev-up/dev-down）与签发链路检查
├── .gitignore
└── docker-compose.yml
```

## 启动

### 签发链路一键联调（推荐）

报告编制、审核、签发三段跨前后端，推荐直接用工程化脚本，一条命令完成
「依赖/端口预检 → 安装依赖 → 构建前端 → 拉起前后端 → 写入示例数据」：

```bash
make dev-up        # 等价于 scripts/dev-up.sh
```

脚本会：

- 检查 `python3` / `node` / `npm`，缺失时打印对应安装方式并退出；
- 检查后端 `8000`、前端 `5173` 端口，被占用时给出占用排查命令并退出
  （可用 `BACKEND_PORT=xxxx make dev-up` 换端口）；
- 按需创建 `backend/.venv`、安装前端依赖，并执行 `npm run build`
  （含 `vue-tsc` 类型检查）；
- 后台拉起 `uvicorn` 与 `vite preview`（跑构建产物，`/api` 代理到后端），
  轮询健康检查与前后端联通性，日志在 `.run/logs/`，pid 在 `.run/*.pid`；
- 后端是内存仓库，启动即写入示例数据：报告模块固定有
  「待编制 / 待审核 / 待签发 / 已签发」各一条，含报告编号、编制人、审核人、
  签发人（已签发条由 `周签发` 签发并带报告结论）。

启动后打开 `http://127.0.0.1:5173/report` 即可逐段点「编制报告 / 审核通过 /
签发报告」。停止服务：

```bash
make dev-down      # 等价于 scripts/dev-down.sh
```

签发完成后（或想随时复验），跑可复现检查脚本：它会新建一份报告，严格按
待编制→待审核→待签发→已签发推进（跳步、缺结论等非法动作必须被拒绝），
再从明细、列表、导出三个接口取回报告，逐字段比对报告结论与接口返回：

```bash
make check         # 等价于 scripts/check_report_chain.py
```

退出码 0 表示结论一致；也可显式指定地址：
`scripts/check_report_chain.py --backend http://127.0.0.1:8000 --frontend http://127.0.0.1:5173`。

### 后端（手工）

```bash
cd backend
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
./run.sh
```

健康检查：`curl http://127.0.0.1:8000/api/health`

### 前端（手工）

```bash
cd frontend
npm install
npm run dev
```

前端默认监听 `http://127.0.0.1:5173/`，dev server 不会自动打开浏览器，
需要自己访问。`/api` 由 vite 代理到后端 `http://127.0.0.1:8000`。
> 注意：手工分启两个服务时，示例数据只在后端进程内存里；重启后端即回到
> `backend/app/seed.py` 的初始状态，不会有「忘记同步数据库」的问题。

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
| 检测报告 | `report` | 检测报告 | 报告编号、关联任务、编制人 |
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
