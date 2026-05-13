# ─── Provider: Z.AI (GLM / Zhipu AI) ─────────────────────────────────────────
# Zhipu AI's GLM series models. OpenAI-compatible API.
#
# Config:
#   PROVIDER=zai
#   MODEL=glm-4-plus   (or glm-4-flash, glm-4, glm-z1-plus)
#   ZAI_API_KEY=...   (also accepts GLM_API_KEY or Z_AI_API_KEY)

zai_activate() {
  BASE_URL="https://open.bigmodel.cn/api/paas/v4"
  API_KEY="${ZAI_API_KEY:-${GLM_API_KEY:-${Z_AI_API_KEY:-${API_KEY:-}}}}"
}
