module.exports = {
  apps: [
    {
      name: "ama-bot",
      script: "bot.sh",
      interpreter: "bash",
      cwd: __dirname,
      autorestart: true,
      watch: false,
      max_restarts: 10,
      restart_delay: 2000,
      out_file: "logs/bot.log",
      error_file: "logs/bot.error.log",
      merge_logs: true,
      log_date_format: "YYYY-MM-DD HH:mm:ss",
    },
  ],
};
