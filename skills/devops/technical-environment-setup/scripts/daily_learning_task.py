#!/usr/bin/env python3
"""
Daily trading learning task generator and notifier.
Sends task via Telegram at 6am each day.
"""
import datetime
import subprocess
import os

START_DATE = datetime.date(2026, 5, 25)  # First day of learning (today)
TELEGRAM_TARGET = "telegram:Ayomide Bakare (dm)"  # from earlier list

def get_task_info(today: datetime.date):
    """Return (task_string, week, day_in_week) for given date."""
    delta = (today - START_DATE).days
    if delta < 0:
        return ("Learning journey has not started yet. "
                "Please wait for the start date or check your setup.", 0, 0)
    # We assume learning days are Monday-Friday (5 days per week). 
    week = delta // 5 + 1
    day_in_week = delta % 5 + 1
    if week > 30:
        return ("Congratulations! You've completed the 30-week plan. "
                "Now focus on refining your broker prototype and live testing.", week, day_in_week)
    # Provide task based on week and day using the learning plan breakdown.
    if week <= 2:
        phase = "Phase 0 – Foundations"
        focus = "Programming refresher, core math/stat, basic finance concepts"
    elif week <= 6:
        phase = "Phase 1 – Market Mechanics & Data"
        focus = "How exchanges work, order books, market data formats, APIs"
    elif week <= 10:
        phase = "Phase 2 – Statistics & Time-Series for Trading"
        focus = "Statistical tools used in strategy research"
    elif week <= 14:
        phase = "Phase 3 – Algorithmic Trading Basics"
        focus = "Strategy families, execution, risk controls"
    elif week <= 18:
        phase = "Phase 4 – Risk Management & Portfolio Construction"
        focus = "Position sizing, portfolio heat, VaR, stress testing"
    elif week <= 22:
        phase = "Phase 5 – System Architecture & Broker Basics"
        focus = "How a broker/order-routing engine works, FIX, matching engine basics"
    elif week <= 26:
        phase = "Phase 6 – Prototyping a Trading Broker"
        focus = "Assemble components into a prototype broker for local securities & FX"
    else:
        phase = "Phase 7 – Testing, Optimization, & FX Specifics"
        focus = "Stress testing, latency, FX nuances, regulatory basics"
    # Daily breakdown: we can assign activities based on day_in_week (1-5)
    activities = {
        1: "30 min Python review (or relevant reading) + 30 min math/prob + 30 min finance intro + 30 min hands-on",
        2: "30 min reading + 30 min concept + 30 min practice + 30 min coding",
        3: "30 min reading + 30 min concept + 30 min practice + 30 min coding",
        4: "30 min reading + 30 min concept + 30 min practice + 30 min coding",
        5: "30 min review + 30 min practice + 30 min coding + 30 min reflection"
    }
    activity = activities.get(day_in_week, "Follow the daily breakdown from the learning plan.")
    task = (f"**{phase} - Week {week}, Day {day_in_week}**\n"
            f"Focus: {focus}\n"
            f"Suggested activity (2h total): {activity}\n"
            f"Remember to log your progress in your daily note and update your Obsidian vault.")
    return task, week, day_in_week

def main():
    today = datetime.date.today()
    task, week, day_in_week = get_task_info(today)
    # Determine phase folder based on week
    if week <= 2:
        phase_folder = "Phase0-Foundations"
    elif week <= 6:
        phase_folder = "Phase1-MarketMechanics"
    elif week <= 10:
        phase_folder = "Phase2-Statistics"
    elif week <= 14:
        phase_folder = "Phase3-Algos"
    elif week <= 18:
        phase_folder = "Phase4-Risk"
    elif week <= 22:
        phase_folder = "Phase5-Architecture"
    elif week <= 26:
        phase_folder = "Phase6-Prototype"
    else:
        phase_folder = "Phase7-Testing"
    # Send via Telegram using hermes CLI
    # Ensure we escape the message properly for CLI
    # We'll use single quotes around the message and escape any single quotes inside.
    # Replace single quotes with '\\'' for safe inclusion in a single-quoted string.
    message_escaped = task.replace("'", "'\\\\''")
    cmd = f"hermes send_message --target '{TELEGRAM_TARGET}' --message '{message_escaped}'"
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    # Log the sent task
    log_dir = os.path.expanduser(f'~/Obsidian/Trading/LEARNING')
    log_path = os.path.join(log_dir, phase_folder, 'daily-task-log.md')
    os.makedirs(os.path.dirname(log_path), exist_ok=True)
    with open(log_path, 'a') as f:
        f.write(f"## {today.isoformat()}\\n\\n")
        f.write(f"Task sent: {task}\\n\\n")
        f.write(f"CLI command: {cmd}\\n\\n")
        f.write(f"Result: {result.returncode}, stdout: {result.stdout[:200]}, stderr: {result.stderr[:200]}\\n\\n\\n")
    # Also print for debugging
    print(f"Sent task for {today}: {task}")

if __name__ == '__main__':
    main()