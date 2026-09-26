.PHONY: setup install backend frontend build up dev down check check-flow preflight

# 幂等安装前后端依赖（venv 损坏会自动重建）
setup install:
	bash scripts/setup.sh

# 前置检查：命令、端口占用、依赖是否就绪
preflight:
	bash scripts/preflight.sh

# 只构建前端
build:
	cd frontend && npm run build

# 一条命令：检查 -> 构建 -> 拉起前后端 -> 写入签发链路示例数据 -> 一致性检查
up dev:
	bash scripts/dev-up.sh

# 不重新构建，直接拉起（前提是已经跑过一次 make up 或 make build）
up-fast:
	bash scripts/dev-up.sh --no-build

# 停止本地前后端进程
down:
	bash scripts/dev-down.sh

# 服务运行期间反复执行的可复现检查：报告结论与接口返回一致
check:
	backend/.venv/bin/python scripts/verify_report.py

# 只重跑签发链路数据（待编制 -> 已签发，幂等）
check-flow:
	backend/.venv/bin/python scripts/run_report_flow.py

# 以下两个目标保留给手工分别起服务的老习惯
backend:
	cd backend && ./run.sh

frontend:
	cd frontend && npm run dev
