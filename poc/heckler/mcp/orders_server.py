#!/usr/bin/env python3
"""A test fixture: the smallest MCP server that can stand in for a team's own system.

It speaks MCP over stdin and stdout (one JSON-RPC message a line) and offers one tool,
order_status. Nothing in it is real. Stand's brain is given it by poc/heckler/operator-brain.json,
so that a rehearsal can show the brain asking its human for a yes and then using a tool.
"""
import json
import sys

ORDERS = {
    "juniper": "The Juniper order has been waiting on stock for 3 days. The warehouse expects the part on Friday, and it ships the same day.",
    "harbour": "The Harbour order shipped on Monday and is due on Wednesday.",
}

TOOLS = [{
    "name": "order_status",
    "description": "Where an order is, and what it is waiting on. Orders are known by a name, such as Juniper.",
    "inputSchema": {"type": "object", "properties": {"order": {"type": "string", "description": "The order's name, such as Juniper."}},
                    "required": ["order"]},
}, {
    "name": "cancel_order",
    "description": "Cancels an order. It cannot be brought back afterwards.",
    "inputSchema": {"type": "object", "properties": {"order": {"type": "string", "description": "The order's name, such as Harbour."}},
                    "required": ["order"]},
}]


def reply(message_id, result=None, error=None):
    message = {"jsonrpc": "2.0", "id": message_id}
    if error is not None:
        message["error"] = error
    else:
        message["result"] = result
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


for line in sys.stdin:
    try:
        message = json.loads(line)
    except ValueError:
        continue
    method, message_id = message.get("method"), message.get("id")
    if message_id is None:
        continue  # a notification: nothing to answer
    if method == "initialize":
        reply(message_id, {"protocolVersion": message.get("params", {}).get("protocolVersion", "2025-06-18"),
                           "capabilities": {"tools": {}}, "serverInfo": {"name": "orders", "version": "0.1"}})
    elif method == "ping":
        reply(message_id, {})
    elif method == "tools/list":
        reply(message_id, {"tools": TOOLS})
    elif method == "tools/call":
        arguments = message.get("params", {}).get("arguments", {})
        name = str(arguments.get("order", "")).lower().replace("order", "").replace("the", "").strip()
        if name not in ORDERS:
            text = "There is no order called %s." % (name or "that")
        elif message.get("params", {}).get("name") == "cancel_order":
            ORDERS[name] = "The %s order was cancelled today." % name.capitalize()
            text = "The %s order is now cancelled." % name.capitalize()
        else:
            text = ORDERS[name]
        reply(message_id, {"content": [{"type": "text", "text": text}], "isError": False})
    else:
        reply(message_id, error={"code": -32601, "message": "Method not found: %s" % method})
