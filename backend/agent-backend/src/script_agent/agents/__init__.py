"""
Human-maintained LangGraph agents only.

Each agent module owns: hard-coded ``*_AGENT_LLM`` dict, system prompt, tools, and graph wiring.
Shared OpenAI-compatible **endpoint + API key** stay in ``script_agent.config.settings`` (``SCRIPT_LLM_*``).
"""
