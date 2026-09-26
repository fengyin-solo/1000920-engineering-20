.PHONY: install backend frontend dev-up dev-down check

install:
	cd backend && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
	cd frontend && npm install

backend:
	cd backend && ./run.sh

frontend:
	cd frontend && npm run dev

# 一条命令：检查依赖/端口 -> 安装依赖 -> 构建前端 -> 拉起前后端（后台）并写入示例数据
dev-up:
	@scripts/dev-up.sh

# 停止 dev-up 拉起的前后端
dev-down:
	@scripts/dev-down.sh

# 签发链路可复现检查：推进一份报告到已签发，并比对各接口返回的报告结论
check:
	@scripts/check_report_chain.py
