# AI-Costs-Workbook

This is an Azure Workbook that gives visibility into Azure OpenAI spend across your Foundry accounts and projects.
What it does today:
Cost and token breakdown by model, account, and project (with drill-down)
Month-over-month cost & token trends with growth tracking
Interaction analytics (latency, reliability, throttle rates)
Cost forecast simulator — select a model and project costs at different user scales
How it works: We pull data from multiple sources into a Log Analytics Workspace (Cost Management API, Diagnostic Settings, Platform Metrics) and visualize it through a single workbook. The README has step-by-step deployment instructions.
Important context: This is a work in progress. We've been iterating based on feedback on what teams want to see and how they want to slice the data. It may not be perfect yet — we'd welcome your feedback on:
What views/metrics matter most to you?
How do you want to group data? (by team, project, model, user?)
What questions do you need this dashboard to answer for leadership?
Your input directly shapes what we build next. Happy to walk through it together if that's easier.
