#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Re-sync the rewritten V1.3.1 PRD markdown into the EXISTING user-owned Feishu docx
(in the V1.3.0 wiki folder), preserving creator = user.

Pipeline:
  1) upload new md -> drive import_task -> temp bot-owned docx
  2) polish temp docx: mermaid code(14) -> flowchart add_ons(40); tables(31) header_row=true
  3) clear target doc body (delete all top-level children)
  4) clone polished temp -> target (faithful: headings/text/bullets/quote/divider/tables/add_ons)
  5) delete temp docx

Usage:
  python3 .pwtest/fb_v131_resync.py        # DRY
  python3 .pwtest/fb_v131_resync.py apply
"""
import sys, json, time, uuid, urllib.request
sys.path.insert(0, "/Users/lishuang/Documents/Cursor/Dino English/appstore-scripts/pricing/_fb")
import lark_auth as L

MD = "/Users/lishuang/Documents/Cursor/Dino English/V1.3.2-产品需求文档-PRD.md"
TITLE = "Dino English V1.3.2版本产品需求文档（temp resync）"
TGT = "O2xqdiawQo6gqUxnMDaj4aTrpDd"   # user-owned doc to refresh in place
FLOW_CTID = "blk_640017963d808005a21a6445"
APPLY = len(sys.argv) > 1 and sys.argv[1] == "apply"

META = {"block_id", "parent_id", "block_type", "children"}
TEXTLIKE = {2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 15}
KEYMAP = {2: "text", 3: "heading1", 4: "heading2", 5: "heading3", 6: "heading4",
          7: "heading5", 8: "heading6", 9: "heading7", 10: "heading8", 11: "heading9",
          12: "bullet", 13: "ordered", 15: "quote"}


def all_blocks(tok, doc):
    items, pt = [], None
    while True:
        url = f"/open-apis/docx/v1/documents/{doc}/blocks?page_size=500" + (f"&page_token={pt}" if pt else "")
        d = L.api("GET", url, tok)["data"]
        items += d.get("items", [])
        pt = d.get("page_token")
        if not d.get("has_more"):
            break
    return items


def page_order(items):
    page = next(x for x in items if x.get("block_type") == 1)
    return page.get("children", []), {x["block_id"]: x for x in items}


# ---------- step 1: import md -> temp docx ----------

def root_folder(tok):
    return L.api("GET", "/open-apis/drive/explorer/v2/root_folder/meta", tok)["data"]["token"]


def upload_all(tok, folder, name, data):
    boundary = "----dino" + uuid.uuid4().hex
    parts = []
    def field(n, v):
        parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{n}\"\r\n\r\n{v}\r\n".encode())
    field("file_name", name); field("parent_type", "explorer")
    field("parent_node", folder); field("size", str(len(data)))
    parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{name}\"\r\nContent-Type: text/markdown\r\n\r\n".encode())
    parts.append(data); parts.append(f"\r\n--{boundary}--\r\n".encode())
    body = b"".join(parts)
    req = urllib.request.Request(f"{L.BASE}/open-apis/drive/v1/files/upload_all", data=body, method="POST",
                                 headers={"Authorization": f"Bearer {tok}",
                                          "Content-Type": f"multipart/form-data; boundary={boundary}"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read().decode())


def import_md(tok):
    data = open(MD, "rb").read()
    folder = root_folder(tok)
    up = upload_all(tok, folder, "V1.3.1-PRD-resync.md", data)
    ft = up["data"]["file_token"]
    imp = L.api("POST", "/open-apis/drive/v1/import_tasks", tok, {
        "file_extension": "md", "file_token": ft, "type": "docx",
        "file_name": TITLE, "point": {"mount_type": 1, "mount_key": folder}})
    ticket = imp["data"]["ticket"]
    for i in range(40):
        time.sleep(2)
        res = L.api("GET", f"/open-apis/drive/v1/import_tasks/{ticket}", tok).get("data", {}).get("result", {})
        js = res.get("job_status")
        print(f"    import poll {i}: job_status={js} {res.get('job_error_msg','')}")
        if js == 0:
            return res.get("token")
        if js not in (1, 2, None):
            raise SystemExit(f"import failed: {res}")
    raise SystemExit("import did not finish")


# ---------- step 2: polish temp docx ----------

def code_text(b):
    return "".join(e.get("text_run", {}).get("content", "") for e in b.get("code", {}).get("elements", []))


def polish(tok, doc):
    def conv_mermaid():
        items = all_blocks(tok, doc); order, _ = page_order(items)
        for x in items:
            if x.get("block_type") == 14:
                t = code_text(x)
                if "flowchart" in t or t.strip().startswith("graph"):
                    idx = order.index(x["block_id"])
                    rec = json.dumps({"data": t, "theme": "default", "view": "chart"}, ensure_ascii=False)
                    addon = {"block_type": 40, "add_ons": {"component_type_id": FLOW_CTID, "record": rec}}
                    r = L.api("POST", f"/open-apis/docx/v1/documents/{doc}/blocks/{doc}/children", tok,
                              {"children": [addon], "index": idx})
                    if r.get("code") != 0:
                        print("  [!] addon:", json.dumps(r, ensure_ascii=False)[:200]); return "err"
                    L.api("DELETE", f"/open-apis/docx/v1/documents/{doc}/blocks/{doc}/children/batch_delete", tok,
                          {"start_index": idx + 1, "end_index": idx + 2})
                    print(f"  [ok] mermaid#{idx} -> add_ons"); return "done"
        return None

    def cell_children(bid, cell):
        out = []
        for ch_id in cell.get("children", []):
            ch = bid[ch_id]; bt = ch.get("block_type")
            key = {2: "text", 12: "bullet", 13: "ordered"}.get(bt, "text")
            src = ch.get(key) or ch.get("text") or {"elements": []}
            els = [{"text_run": {"content": e["text_run"].get("content", ""),
                                 "text_element_style": e["text_run"].get("text_element_style", {})}}
                   for e in src.get("elements", []) if e.get("text_run")]
            out.append((bt if bt in (2, 12, 13) else 2, key, els))
        return out or [(2, "text", [])]

    def rebuild_table():
        items = all_blocks(tok, doc); order, bid = page_order(items)
        for x in items:
            if x.get("block_type") == 31 and not x["table"]["property"].get("header_row"):
                idx = order.index(x["block_id"]); prop = x["table"]["property"]
                cells = x["table"].get("cells", [])
                np = {"row_size": prop["row_size"], "column_size": prop["column_size"], "header_row": True}
                if prop.get("column_width"):
                    np["column_width"] = prop["column_width"]
                desc = []; cell_ids = []
                for k, cid in enumerate(cells):
                    tcell = f"t_c{k}"; cell_ids.append(tcell)
                    cids = []; cdesc = []
                    for j, (bt, key, els) in enumerate(cell_children(bid, bid[cid])):
                        tid = f"t_c{k}_{j}"; cids.append(tid)
                        cdesc.append({"block_id": tid, "block_type": bt, key: {"elements": els}})
                    desc.append({"block_id": tcell, "block_type": 32, "table_cell": {}, "children": cids})
                    desc += cdesc
                desc = [{"block_id": "t_table", "block_type": 31, "table": {"property": np}, "children": cell_ids}] + desc
                r = L.api("POST", f"/open-apis/docx/v1/documents/{doc}/blocks/{doc}/descendant", tok,
                          {"index": idx, "children_id": ["t_table"], "descendants": desc})
                if r.get("code") != 0:
                    print("  [!] table:", json.dumps(r, ensure_ascii=False)[:300]); return "err"
                L.api("DELETE", f"/open-apis/docx/v1/documents/{doc}/blocks/{doc}/children/batch_delete", tok,
                      {"start_index": idx + 1, "end_index": idx + 2})
                print(f"  [ok] table#{idx} header_row"); return "done"
        return None

    print("  -- mermaid pass --")
    while conv_mermaid() == "done":
        time.sleep(0.7)
    print("  -- table header-row pass --")
    while rebuild_table() == "done":
        time.sleep(0.7)


# ---------- step 4: clone ----------

def clean_elements(els):
    out = []
    for e in els or []:
        tr = e.get("text_run")
        if tr is not None:
            out.append({"text_run": {"content": tr.get("content", ""),
                                     "text_element_style": tr.get("text_element_style", {})}})
        else:
            out.append(e)
    return out


class Builder:
    def __init__(self, bid):
        self.bid = bid; self.n = 0
    def tid(self):
        self.n += 1; return f"t{self.n}"
    def build(self, src_id, descendants):
        b = self.bid[src_id]; bt = b["block_type"]; tid = self.tid()
        spec = {"block_id": tid, "block_type": bt}
        if bt in TEXTLIKE:
            key = KEYMAP[bt]
            spec[key] = {"elements": clean_elements(b.get(key, {}).get("elements", []))}
            if b.get("children"):
                spec["children"] = [self.build(c, descendants) for c in b["children"]]
        elif bt == 22:
            spec["divider"] = {}
        elif bt == 40:
            ao = b.get("add_ons", {})
            spec["add_ons"] = {"component_type_id": ao.get("component_type_id", ""), "record": ao.get("record", "")}
        elif bt == 31:
            p = b["table"]["property"]
            prop = {"row_size": p["row_size"], "column_size": p["column_size"], "header_row": True}
            if p.get("column_width"):
                prop["column_width"] = p["column_width"]
            spec["table"] = {"property": prop}
            spec["children"] = [self.build(c, descendants) for c in (b["table"].get("cells") or b.get("children", []))]
        elif bt == 32:
            spec["table_cell"] = {}
            spec["children"] = [self.build(c, descendants) for c in b.get("children", [])]
        else:
            spec["text"] = {"elements": []}
        descendants.append(spec)
        return tid


def clear_target(tok):
    items = all_blocks(tok, TGT)
    top, _ = page_order(items)
    if not top:
        print("  [i] target already empty"); return
    L.api("DELETE", f"/open-apis/docx/v1/documents/{TGT}/blocks/{TGT}/children/batch_delete", tok,
          {"start_index": 0, "end_index": len(top)})
    print(f"  [ok] cleared {len(top)} top-level blocks from target")


def clone(tok, src):
    items = all_blocks(tok, src)
    top, bid = page_order(items)
    bld = Builder(bid)
    for i, cid in enumerate(top):
        desc = []
        root = bld.build(cid, desc)
        r = L.api("POST", f"/open-apis/docx/v1/documents/{TGT}/blocks/{TGT}/descendant", tok,
                  {"index": i, "children_id": [root], "descendants": desc})
        if r.get("code") != 0:
            print(f"  [!] block {i} (type {bid[cid]['block_type']}):", json.dumps(r, ensure_ascii=False)[:300])
            return False
        time.sleep(0.15)
    print(f"  [ok] cloned {len(top)} top-level blocks into target")
    return True


def main():
    tok = L.tenant_token()
    if not APPLY:
        print("[DRY] would: import new md -> temp docx; polish; clear", TGT, "; clone; delete temp")
        items = all_blocks(tok, TGT); top, _ = page_order(items)
        print(f"[DRY] target currently has {len(top)} top-level blocks")
        return
    print("[1] import new markdown -> temp docx")
    temp = import_md(tok)
    print("    temp docx =", temp)
    print("[2] polish temp docx")
    polish(tok, temp)
    print("[3] clear target body")
    clear_target(tok)
    print("[4] clone temp -> target")
    ok = clone(tok, temp)
    if ok:
        print("[5] delete temp docx")
        d = L.api("DELETE", f"/open-apis/drive/v1/files/{temp}?type=docx", tok)
        print("    delete temp:", d.get("code"), d.get("msg"))
    # verify
    items = all_blocks(tok, TGT)
    from collections import Counter
    c = Counter(x.get("block_type") for x in items)
    th = sum(1 for x in items if x.get("block_type") == 31 and x["table"]["property"].get("header_row"))
    print("[verify] target types:", dict(sorted(c.items())), "tables_with_header:", th, "add_ons:", c.get(40, 0))


if __name__ == "__main__":
    main()
