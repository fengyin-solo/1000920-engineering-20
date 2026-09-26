<template>
  <section class="page" data-module="report">
    <header class="page-head">
      <div>
        <h2>检测报告管理</h2>
        <p class="page-desc">维护检测报告，围绕报告编号、关联任务、编制人、审核人做登记、筛选与状态流转。</p>
      </div>
      <div class="page-actions">
        <button class="btn primary" type="button" @click="openCreate">登记检测报告</button>
        <button class="btn" type="button" @click="exportRows">导出检测报告清单</button>
      </div>
    </header>

    <div class="stat-row">
      <article v-for="item in stats" :key="item.label" class="stat-card">
        <span class="stat-label">{{ item.label }}</span>
        <strong class="stat-value">{{ item.value }}</strong>
      </article>
    </div>

    <form class="filter-bar" @submit.prevent="reload">
      <label v-for="field in filterFields" :key="field" class="filter-item">
        <span>{{ field }}</span>
        <input v-model="filters[field]" :placeholder="`按${field}检索`" />
      </label>
      <button class="btn" type="submit">查询</button>
      <button class="btn ghost" type="button" @click="resetFilters">重置条件</button>
    </form>

    <table class="data-table">
      <thead>
        <tr>
          <th v-for="column in columns" :key="column">{{ column }}</th>
          <th>可执行动作</th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="row in rows" :key="String(row.id)">
          <td v-for="column in columns" :key="column">{{ row[column] ?? '—' }}</td>
          <td class="row-actions">
            <button
              v-for="action in availableActions(String(row.status))"
              :key="action"
              class="link"
              type="button"
              @click="runAction(action, row)"
            >
              {{ action }}
            </button>
            <span v-if="!availableActions(String(row.status)).length" class="muted">—</span>
          </td>
        </tr>
        <tr v-if="!rows.length">
          <td :colspan="columns.length + 1" class="empty-state">暂无检测报告数据，可先登记检测报告</td>
        </tr>
      </tbody>
    </table>

    <footer class="page-foot">
      <span>共 {{ total }} 条检测报告记录</span>
      <span v-if="errorMessage" class="error-text">{{ errorMessage }}</span>
    </footer>
  </section>
</template>

<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'

import { request } from '@/api/client'
import { useSessionStore } from '@/stores/session'

type Row = Record<string, string | number | null>

const session = useSessionStore()

const ENDPOINT = '/api/report'
const columns = ["报告编号", "关联任务", "编制人", "审核人", "签发人", "报告日期", "报告类型", "报告结论", "报告状态"]
// 状态与动作一一对应：三段链路只能逐段推进，不能跳步。
const NEXT_ACTION: Record<string, string> = {
  '待编制': '编制报告',
  '待审核': '审核通过',
  '待签发': '签发报告',
}
// 每个动作要随请求带给后端的经办人字段。
const PERSON_FIELD: Record<string, string> = {
  '编制报告': '编制人',
  '审核通过': '审核人',
  '签发报告': '签发人',
}
const SIGN_CONCLUSION = '所检项目结果符合标准限值要求，报告结论：合格。'

const rows = ref<Row[]>([])
const total = ref(0)
const errorMessage = ref('')
const filters = ref<Record<string, string>>({})
const filterFields = columns.slice(0, 3)

const stats = computed(() => {
  const count = (status: string) => rows.value.filter((row) => String(row.status) === status).length
  return [
    { label: '待编制报告', value: count('待编制') },
    { label: '待审核报告', value: count('待审核') },
    { label: '待签发报告', value: count('待签发') },
    { label: '已签发报告', value: count('已签发') },
  ]
})

function availableActions(status: string): string[] {
  const action = NEXT_ACTION[status]
  return action ? [action] : []
}

function resetFilters() {
  filters.value = {}
  void reload()
}

function exportRows() {
  window.open(`${ENDPOINT}/export`, '_blank')
}

function openCreate() {
  errorMessage.value = '检测报告登记入口尚未接入审批流'
}

async function runAction(action: string, row: Row) {
  errorMessage.value = ''
  // 带上当前登录人与（签发时）报告结论；后端缺人或缺结论会拒绝流转。
  const values: Record<string, string> = {
    action,
    [PERSON_FIELD[action]]: session.operator,
  }
  if (action === '签发报告') {
    values['报告结论'] = SIGN_CONCLUSION
  }
  try {
    const response = await request(`${ENDPOINT}/${row.id}/actions`, {
      method: 'POST',
      body: JSON.stringify({ values }),
    })
    const payload = (await response.json().catch(() => null)) as { ok?: boolean; message?: string } | null
    if (!response.ok || !payload?.ok) {
      throw new Error(payload?.message || '检测报告动作未生效，请稍后重试')
    }
    await reload()
  } catch (error) {
    errorMessage.value = error instanceof Error ? error.message : '检测报告操作失败'
  }
}

async function reload() {
  errorMessage.value = ''
  const query = new URLSearchParams(filters.value as Record<string, string>).toString()
  try {
    const response = await request(`${ENDPOINT}?${query}`)
    if (!response.ok) {
      throw new Error('检测报告列表读取失败')
    }
    const payload = await response.json()
    rows.value = payload.items ?? []
    total.value = payload.total ?? rows.value.length
  } catch (error) {
    errorMessage.value = error instanceof Error ? error.message : '检测报告列表读取失败'
  }
}

onMounted(reload)
</script>
