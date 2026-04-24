$ErrorActionPreference = "Stop"

# Zaženi iz korenske mape aplikacije, npr. C:\izposoja
$root = (Get-Location).Path

function Write-Utf8NoBom($Path, $Content) {
    $dir = Split-Path -Parent $Path
    if ($dir -and !(Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

New-Item -ItemType Directory -Path (Join-Path $root "asset_images") -Force | Out-Null
if (!(Test-Path (Join-Path $root "asset_images\.gitkeep"))) { Write-Utf8NoBom (Join-Path $root "asset_images\.gitkeep") "" }

$inventoryPy = @'
from __future__ import annotations

import sqlite3
import uuid
from contextlib import closing
from datetime import datetime
from pathlib import Path
from typing import Optional

from fastapi import APIRouter, File, Form, Request, UploadFile
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates

router = APIRouter()
templates = Jinja2Templates(directory="app/templates")

IMAGE_DIR = Path("asset_images")
ALLOWED_IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".webp", ".gif"}
MAX_IMAGE_BYTES = 8 * 1024 * 1024


def _get_db_path() -> Path:
    from app.core.config import get_settings
    return Path(get_settings().database.sqlite_path)


def _connect() -> sqlite3.Connection:
    db_path = _get_db_path()
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    return conn


def _ensure_table() -> None:
    with closing(_connect()) as conn:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS inventory_items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                inventory_number TEXT,
                total_quantity INTEGER NOT NULL DEFAULT 0,
                available_quantity INTEGER NOT NULL DEFAULT 0,
                damaged_quantity INTEGER NOT NULL DEFAULT 0,
                storage_location TEXT NOT NULL,
                notes TEXT,
                image_filename TEXT,
                is_active INTEGER NOT NULL DEFAULT 1,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
        """)
        existing_columns = {row[1] for row in conn.execute("PRAGMA table_info(inventory_items)").fetchall()}
        if "image_filename" not in existing_columns:
            conn.execute("ALTER TABLE inventory_items ADD COLUMN image_filename TEXT")
        if "is_active" not in existing_columns:
            conn.execute("ALTER TABLE inventory_items ADD COLUMN is_active INTEGER NOT NULL DEFAULT 1")
        if "created_at" not in existing_columns:
            conn.execute("ALTER TABLE inventory_items ADD COLUMN created_at TEXT")
        if "updated_at" not in existing_columns:
            conn.execute("ALTER TABLE inventory_items ADD COLUMN updated_at TEXT")
        conn.commit()


def _safe_image_name(original_filename: str) -> str:
    suffix = Path(original_filename or "").suffix.lower()
    if suffix not in ALLOWED_IMAGE_SUFFIXES:
        raise ValueError("Dovoljene so samo slike JPG, PNG, WEBP ali GIF.")
    return f"{uuid.uuid4().hex}{suffix}"


async def _save_image(image: UploadFile | None) -> str | None:
    if image is None or not image.filename:
        return None
    filename = _safe_image_name(image.filename)
    data = await image.read()
    if not data:
        return None
    if len(data) > MAX_IMAGE_BYTES:
        raise ValueError("Slika je prevelika. Največja dovoljena velikost je 8 MB.")
    IMAGE_DIR.mkdir(parents=True, exist_ok=True)
    (IMAGE_DIR / filename).write_bytes(data)
    return filename


def _delete_image(filename: str | None) -> None:
    if not filename:
        return
    safe_name = Path(filename).name
    path = IMAGE_DIR / safe_name
    if path.exists() and path.is_file():
        path.unlink(missing_ok=True)


def _append_note(existing: Optional[str], extra: str) -> str:
    existing = (existing or "").strip()
    extra = extra.strip()
    if not extra:
        return existing
    stamp = datetime.now().strftime("%d.%m.%Y %H:%M")
    line = f"[{stamp}] {extra}"
    return existing + "\n" + line if existing else line


def _require_login(request: Request):
    user = request.session.get("user")
    if not user:
        return RedirectResponse(url="/login", status_code=303)
    return None


def _require_admin(request: Request):
    user = request.session.get("user")
    if not user:
        return RedirectResponse(url="/login", status_code=303)
    if user.get("role") != "admin":
        return RedirectResponse(url="/dashboard", status_code=303)
    return None


SELECT_COLUMNS = """
    id, name, inventory_number, total_quantity, available_quantity,
    damaged_quantity, storage_location, notes, image_filename, is_active
"""


@router.get("/inventory", response_class=HTMLResponse)
def inventory_overview(request: Request, status: Optional[str] = None):
    guard = _require_login(request)
    if guard:
        return guard
    _ensure_table()
    with closing(_connect()) as conn:
        if status == "damaged":
            rows = conn.execute(f"""SELECT {SELECT_COLUMNS} FROM inventory_items WHERE damaged_quantity > 0 ORDER BY name COLLATE NOCASE""").fetchall()
            page_title = "Poškodovana oprema"
            subtitle = "Pregled opreme s poškodbami."
            empty_text = "Ni poškodovane opreme"
        else:
            rows = conn.execute(f"""SELECT {SELECT_COLUMNS} FROM inventory_items WHERE is_active = 1 ORDER BY name COLLATE NOCASE""").fetchall()
            page_title = "Pregled zaloge"
            subtitle = "Trenutno stanje opreme."
            empty_text = "Ni vnesene opreme"
    return templates.TemplateResponse("inventory_list.html", {"request": request, "title": page_title, "page_title": page_title, "subtitle": subtitle, "items": rows, "empty_text": empty_text, "is_damaged_view": status == "damaged"})


@router.get("/inventory/manage", response_class=HTMLResponse)
def inventory_manage(request: Request, edit_id: Optional[int] = None, show_inactive: int = 0):
    guard = _require_admin(request)
    if guard:
        return guard
    _ensure_table()
    with closing(_connect()) as conn:
        if show_inactive:
            items = conn.execute(f"""SELECT {SELECT_COLUMNS} FROM inventory_items ORDER BY is_active DESC, name COLLATE NOCASE""").fetchall()
        else:
            items = conn.execute(f"""SELECT {SELECT_COLUMNS} FROM inventory_items WHERE is_active = 1 ORDER BY name COLLATE NOCASE""").fetchall()
        item_to_edit = None
        if edit_id is not None:
            item_to_edit = conn.execute(f"""SELECT {SELECT_COLUMNS} FROM inventory_items WHERE id = ?""", (edit_id,)).fetchone()
    return templates.TemplateResponse("inventory_manage.html", {"request": request, "title": "Šifrant opreme", "items": items, "item_to_edit": item_to_edit, "show_inactive": show_inactive, "error": request.query_params.get("error")})


@router.post("/inventory/manage/create")
async def inventory_create(request: Request, name: str = Form(...), inventory_number: str = Form(""), total_quantity: int = Form(...), damaged_quantity: int = Form(0), storage_location: str = Form(...), notes: str = Form(""), image: UploadFile | None = File(None)):
    guard = _require_admin(request)
    if guard:
        return guard
    _ensure_table()
    total_quantity = max(0, int(total_quantity))
    damaged_quantity = max(0, int(damaged_quantity))
    if damaged_quantity > total_quantity:
        damaged_quantity = total_quantity
    available_quantity = max(0, total_quantity - damaged_quantity)
    now = datetime.now().isoformat(timespec="seconds")
    try:
        image_filename = await _save_image(image)
    except ValueError as exc:
        return RedirectResponse(url=f"/inventory/manage?error={str(exc)}", status_code=303)
    with closing(_connect()) as conn:
        conn.execute("""INSERT INTO inventory_items (name, inventory_number, total_quantity, available_quantity, damaged_quantity, storage_location, notes, image_filename, is_active, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)""", (name.strip(), inventory_number.strip(), total_quantity, available_quantity, damaged_quantity, storage_location.strip(), notes.strip(), image_filename, now, now))
        conn.commit()
    return RedirectResponse(url="/inventory/manage", status_code=303)


@router.post("/inventory/manage/image/{item_id}")
async def inventory_update_image(request: Request, item_id: int, image: UploadFile | None = File(None), remove_image: int = Form(0)):
    guard = _require_admin(request)
    if guard:
        return guard
    _ensure_table()
    with closing(_connect()) as conn:
        current = conn.execute("SELECT image_filename FROM inventory_items WHERE id = ?", (item_id,)).fetchone()
        current_image = current["image_filename"] if current else None
        new_image = current_image
        try:
            uploaded = await _save_image(image)
        except ValueError as exc:
            return RedirectResponse(url=f"/inventory/manage?error={str(exc)}", status_code=303)
        if uploaded:
            _delete_image(current_image)
            new_image = uploaded
        elif int(remove_image):
            _delete_image(current_image)
            new_image = None
        conn.execute("UPDATE inventory_items SET image_filename = ?, updated_at = ? WHERE id = ?", (new_image, datetime.now().isoformat(timespec="seconds"), item_id))
        conn.commit()
    return RedirectResponse(url="/inventory/manage", status_code=303)


@router.post("/inventory/manage/edit/{item_id}")
async def inventory_update(request: Request, item_id: int, name: str = Form(...), inventory_number: str = Form(""), total_quantity: int = Form(...), available_quantity: int = Form(...), damaged_quantity: int = Form(...), storage_location: str = Form(...), notes: str = Form(""), is_active: int = Form(1), image: UploadFile | None = File(None), remove_image: int = Form(0)):
    guard = _require_admin(request)
    if guard:
        return guard
    _ensure_table()
    total_quantity = max(0, int(total_quantity)); available_quantity = max(0, int(available_quantity)); damaged_quantity = max(0, int(damaged_quantity))
    if available_quantity + damaged_quantity > total_quantity:
        available_quantity = max(0, total_quantity - damaged_quantity)
    now = datetime.now().isoformat(timespec="seconds")
    with closing(_connect()) as conn:
        current = conn.execute("SELECT image_filename FROM inventory_items WHERE id = ?", (item_id,)).fetchone()
        current_image = current["image_filename"] if current else None
        new_image = current_image
        try:
            uploaded = await _save_image(image)
        except ValueError as exc:
            return RedirectResponse(url=f"/inventory/manage?error={str(exc)}", status_code=303)
        if uploaded:
            _delete_image(current_image); new_image = uploaded
        elif int(remove_image):
            _delete_image(current_image); new_image = None
        conn.execute("""UPDATE inventory_items SET name = ?, inventory_number = ?, total_quantity = ?, available_quantity = ?, damaged_quantity = ?, storage_location = ?, notes = ?, image_filename = ?, is_active = ?, updated_at = ? WHERE id = ?""", (name.strip(), inventory_number.strip(), total_quantity, available_quantity, damaged_quantity, storage_location.strip(), notes.strip(), new_image, 1 if int(is_active) else 0, now, item_id))
        conn.commit()
    return RedirectResponse(url="/inventory/manage", status_code=303)


@router.post("/inventory/manage/deactivate/{item_id}")
def inventory_deactivate(request: Request, item_id: int):
    guard = _require_admin(request)
    if guard:
        return guard
    _ensure_table()
    with closing(_connect()) as conn:
        conn.execute("UPDATE inventory_items SET is_active = 0, updated_at = ? WHERE id = ?", (datetime.now().isoformat(timespec="seconds"), item_id))
        conn.commit()
    return RedirectResponse(url="/inventory/manage?show_inactive=1", status_code=303)


@router.post("/inventory/manage/activate/{item_id}")
def inventory_activate(request: Request, item_id: int):
    guard = _require_admin(request)
    if guard:
        return guard
    _ensure_table()
    with closing(_connect()) as conn:
        conn.execute("UPDATE inventory_items SET is_active = 1, updated_at = ? WHERE id = ?", (datetime.now().isoformat(timespec="seconds"), item_id))
        conn.commit()
    return RedirectResponse(url="/inventory/manage?show_inactive=1", status_code=303)


@router.post("/inventory/manage/adjust/{item_id}")
def inventory_adjust(request: Request, item_id: int, total_quantity: int = Form(...), available_quantity: int = Form(...), damaged_quantity: int = Form(...), reason: str = Form("")):
    guard = _require_admin(request)
    if guard:
        return guard
    _ensure_table()
    total_quantity = max(0, int(total_quantity)); available_quantity = max(0, int(available_quantity)); damaged_quantity = max(0, int(damaged_quantity))
    if available_quantity + damaged_quantity > total_quantity:
        available_quantity = max(0, total_quantity - damaged_quantity)
    with closing(_connect()) as conn:
        row = conn.execute("SELECT notes FROM inventory_items WHERE id = ?", (item_id,)).fetchone()
        notes = _append_note(row["notes"] if row else "", f"Ročni popravek zaloge. Razlog: {reason or 'ni naveden'}")
        conn.execute("""UPDATE inventory_items SET total_quantity = ?, available_quantity = ?, damaged_quantity = ?, notes = ?, updated_at = ? WHERE id = ?""", (total_quantity, available_quantity, damaged_quantity, notes, datetime.now().isoformat(timespec="seconds"), item_id))
        conn.commit()
    return RedirectResponse(url="/inventory/manage?show_inactive=1", status_code=303)
'@
Write-Utf8NoBom (Join-Path $root "app\web\inventory.py") $inventoryPy

# Popravi šumnike v JS/HTML datotekah
$replacements = @{
    'najhitrejÄąË‡e'='najhitrejše'; 'priporoĂ„Ĺ¤ljiv'='priporočljiv'; 'Ă„Ĺ¤italec'='čitalec';
    'Ă„Ĺšitalec'='Čitalec'; 'roĂ„Ĺ¤ni'='ročni'; 'naĂ„Ĺ¤inu'='načinu'; 'obmoĂ„Ĺ¤je'='območje';
    'ÄąË‡tevilke'='številke'; 'ÄąË‡tevilka'='številka'; 'ÄąÄľe'='že'; 'veĂ„Ĺ¤'='več';
    'koliĂ„Ĺ¤ine'='količine'; 'poÄąË‡kodovano'='poškodovano'; 'ZabeleÄąÄľeno vraĂ„Ĺ¤ilo'='Zabeleženo vračilo';
    'vraĂ„Ĺ¤ilo'='vračilo'; 'najhitrejÄąË‡e vraĂ„Ĺ¤ilo'='najhitrejše vračilo';
    'E-posta'='E-pošta'; 'poskodbe'='poškodbe'; 'poskodb'='poškodb'; 'stevilki'='številki';
    'stevilko'='številko'; 'stevilka'='številka'; 'vpisi'='vpiši'; 'Isci'='Išči'; 'Preklici'='Prekliči';
    'doseĹľena je maksimalna razpoloĹľljiva koliÄŤina'='dosežena je maksimalna razpoložljiva količina';
    'â’'='−'
}
$filesToFix = @(
    "app\static\js\barcode_scanner.js",
    "app\static\js\app.js",
    "app\templates\loans\form.html"
)
foreach ($rel in $filesToFix) {
    $path = Join-Path $root $rel
    if (Test-Path $path) {
        $txt = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        foreach ($k in $replacements.Keys) { $txt = $txt.Replace($k, $replacements[$k]) }
        Write-Utf8NoBom $path $txt
    }
}

# Posodobi HTML za šifrant in pregled zaloge
$managePath = Join-Path $root "app\templates\inventory_manage.html"
$manage = @'
{% extends "base.html" %}
{% block content %}
<div class="page-header">
    <h1>Šifrant opreme</h1>
    <p class="muted">Dodajanje opreme, urejanje količin v vrstici, fotografije in deaktivacija.</p>
</div>

<style>
.inline-edit-table .cell-edit { display: none; }
.inline-edit-table tr.editing .cell-view { display: none; }
.inline-edit-table tr.editing .cell-edit { display: inline-block; }
.inline-edit-table .edit-input,.inline-edit-table .reason-input { min-height:42px;padding:8px 10px;border:1px solid #d5d7dc;border-radius:12px;background:#fff;font-size:15px; }
.inline-edit-table .edit-input { width:88px; }
.inline-edit-table .reason-input { width:220px; }
.inline-edit-table .actions-inline { display:flex;align-items:center;gap:8px;flex-wrap:wrap; }
.inline-edit-table .icon-danger { min-width:42px;min-height:42px;padding:0 12px;border-radius:12px;border:0;background:#c93434;color:#fff;font-size:18px;font-weight:700;cursor:pointer; }
.inline-edit-table .btn-save,.inline-edit-table .btn-cancel { display:none; }
.inline-edit-table tr.editing .btn-save,.inline-edit-table tr.editing .btn-cancel { display:inline-flex; }
.inline-edit-table tr.editing .btn-edit { display:none; }
.inline-edit-table tr.editing .notes-view { display:none; }
.inline-edit-table .notes-edit { display:none; }
.inline-edit-table tr.editing .notes-edit { display:inline-block; }
.inline-edit-table .badge-status { display:inline-flex;align-items:center;min-height:32px;padding:4px 10px;border-radius:999px;background:#eef1f4;font-weight:600;font-size:14px; }
.inline-edit-table .badge-status.active { color:#246b3d;background:#e8f3ec; }
.inline-edit-table .badge-status.inactive { color:#7b1f1f;background:#f8e4e4; }
.inline-edit-table .top-form-grid { display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:12px; }
.inline-edit-table textarea,.inline-edit-table input[type="text"],.inline-edit-table input[type="number"],.inline-edit-table select { width:100%; }
</style>

<div class="card" style="margin-bottom: 16px;">
    <h2>Dodaj opremo</h2>
    {% if error %}<div class="alert danger">{{ error }}</div>{% endif %}
    <form method="post" action="/inventory/manage/create" enctype="multipart/form-data">
        <div class="top-form-grid">
            <div><label>Naziv</label><input type="text" name="name" required></div>
            <div><label>Inventarna številka</label><input type="text" name="inventory_number"></div>
            <div><label>Skupna količina</label><input type="number" min="0" name="total_quantity" required value="0"></div>
            <div><label>Poškodovana količina</label><input type="number" min="0" name="damaged_quantity" required value="0"></div>
            <div><label>Lokacija skladiščenja</label><input type="text" name="storage_location" required></div>
            <div><label>Fotografija artikla</label><input type="file" name="image" accept="image/*"></div>
            <div style="grid-column:1/-1;"><label>Opombe</label><textarea name="notes" rows="3"></textarea></div>
        </div>
        <div style="margin-top: 12px;"><button class="btn" type="submit">Dodaj opremo</button></div>
    </form>
</div>

<div class="card" style="margin-bottom: 16px;">
    <h2>Uvoz opreme iz Excela</h2>
    <p class="muted">Podprt je samo format <strong>.xlsx</strong> z vnaprej določenimi stolpci.</p>
    <form method="post" action="/inventory/import/preview" enctype="multipart/form-data">
        <div class="top-form-grid"><div style="grid-column:1/-1;"><label>Excel datoteka</label><input type="file" name="file" accept=".xlsx" required></div></div>
        <div style="margin-top: 12px; display:flex; gap:12px; flex-wrap:wrap;"><button class="btn" type="submit">Predogled uvoza</button><a class="btn secondary" href="/static/samples/inventory_import_sample.xlsx">Prenesi vzorčni Excel</a></div>
    </form>
</div>

<div class="card inline-edit-table">
    <div style="display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap;">
        <h2>Seznam opreme</h2>
        <div>{% if show_inactive %}<a class="btn secondary" href="/inventory/manage">Skrij neaktivne</a>{% else %}<a class="btn secondary" href="/inventory/manage?show_inactive=1">Prikaži tudi neaktivne</a>{% endif %}</div>
    </div>
    {% if items %}
    <div class="table-wrap"><table><thead><tr><th>ID</th><th>Slika</th><th>Naziv</th><th>Inventarna št.</th><th>Skupaj</th><th>Razpoložljivo</th><th>Poškodovano</th><th>Lokacija</th><th>Status</th><th>Opombe</th><th>Fotografija</th><th>Akcije</th></tr></thead><tbody>
    {% for item in items %}
    <tr id="row-{{ item.id }}">
        <td>{{ item.id }}</td>
        <td>{% if item.image_filename %}<img src="/asset_images/{{ item.image_filename }}" alt="{{ item.name }}" class="loan-item-thumb">{% else %}<div class="loan-item-thumb loan-item-thumb-placeholder">Ni slike</div>{% endif %}</td>
        <td>{{ item.name }}</td><td>{{ item.inventory_number or '-' }}</td>
        <td><span class="cell-view">{{ item.total_quantity }}</span><input class="cell-edit edit-input" type="number" min="0" name="total_quantity" value="{{ item.total_quantity }}" form="adjust-form-{{ item.id }}"></td>
        <td><span class="cell-view">{{ item.available_quantity }}</span><input class="cell-edit edit-input" type="number" min="0" name="available_quantity" value="{{ item.available_quantity }}" form="adjust-form-{{ item.id }}"></td>
        <td><span class="cell-view">{{ item.damaged_quantity }}</span><input class="cell-edit edit-input" type="number" min="0" name="damaged_quantity" value="{{ item.damaged_quantity }}" form="adjust-form-{{ item.id }}"></td>
        <td>{{ item.storage_location }}</td>
        <td>{% if item.is_active %}<span class="badge-status active">Aktivno</span>{% else %}<span class="badge-status inactive">Neaktivno</span>{% endif %}</td>
        <td><span class="notes-view">{{ item.notes or '-' }}</span><input class="notes-edit reason-input" type="text" name="reason" placeholder="Razlog popravka" form="adjust-form-{{ item.id }}"></td>
        <td><form method="post" action="/inventory/manage/image/{{ item.id }}" enctype="multipart/form-data" style="display:flex;flex-direction:column;gap:6px;min-width:190px;"><input type="file" name="image" accept="image/*"><div style="display:flex;gap:6px;flex-wrap:wrap;"><button class="btn tiny secondary" type="submit">Shrani sliko</button>{% if item.image_filename %}<button class="btn tiny secondary" type="submit" name="remove_image" value="1">Odstrani</button>{% endif %}</div></form></td>
        <td><div class="actions-inline"><button type="button" class="btn secondary btn-edit" onclick="enableInlineEdit({{ item.id }})">Uredi</button><button type="submit" class="btn btn-save" form="adjust-form-{{ item.id }}">Shrani</button><button type="button" class="btn secondary btn-cancel" onclick="cancelInlineEdit({{ item.id }})">Prekliči</button>{% if item.is_active %}<form method="post" action="/inventory/manage/deactivate/{{ item.id }}" style="display:inline;"><button type="submit" class="icon-danger" title="Deaktiviraj">⛔</button></form>{% else %}<form method="post" action="/inventory/manage/activate/{{ item.id }}" style="display:inline;"><button type="submit" class="icon-danger" title="Aktiviraj">↺</button></form>{% endif %}<form id="adjust-form-{{ item.id }}" method="post" action="/inventory/manage/adjust/{{ item.id }}"></form></div></td>
    </tr>
    {% endfor %}
    </tbody></table></div>
    {% else %}<p class="empty-text">Ni vnesene opreme</p>{% endif %}
</div>
<script>
function enableInlineEdit(itemId){const row=document.getElementById('row-'+itemId);if(row)row.classList.add('editing');}
function cancelInlineEdit(itemId){const row=document.getElementById('row-'+itemId);if(!row)return;row.querySelectorAll('input[type="number"]').forEach((input)=>{input.value=input.defaultValue;});row.querySelectorAll('input[type="text"]').forEach((input)=>{input.value='';});row.classList.remove('editing');}
</script>
{% endblock %}
'@
Write-Utf8NoBom $managePath $manage

$listPath = Join-Path $root "app\templates\inventory_list.html"
$list = @'
{% extends "base.html" %}
{% block content %}
<div class="page-header"><h1>{{ page_title }}</h1><p class="muted">{{ subtitle }}</p></div>
<div class="card">
{% if items %}
<div class="table-wrap"><table><thead><tr><th>Slika</th><th>Naziv</th><th>Inventarna številka</th><th>Skupna količina</th><th>Razpoložljiva</th><th>Poškodovana</th><th>Lokacija</th><th>Status</th><th>Opombe</th></tr></thead><tbody>
{% for item in items %}<tr><td>{% if item.image_filename %}<img src="/asset_images/{{ item.image_filename }}" alt="{{ item.name }}" class="loan-item-thumb">{% else %}<div class="loan-item-thumb loan-item-thumb-placeholder">Ni slike</div>{% endif %}</td><td>{{ item.name }}</td><td>{{ item.inventory_number or '-' }}</td><td>{{ item.total_quantity }}</td><td>{{ item.available_quantity }}</td><td>{{ item.damaged_quantity }}</td><td>{{ item.storage_location }}</td><td>{% if item.damaged_quantity > 0 and item.available_quantity == 0 %}Poškodovano{% elif item.available_quantity > 0 %}Na zalogi{% else %}Brez razpoložljive zaloge{% endif %}</td><td style="white-space:pre-line;">{{ item.notes or '-' }}</td></tr>{% endfor %}
</tbody></table></div>
{% else %}<p class="empty-text">{{ empty_text }}</p>{% endif %}
</div>
{% endblock %}
'@
Write-Utf8NoBom $listPath $list

# Preveri Python sintakso
python -m py_compile (Join-Path $root "app\web\inventory.py")
Write-Host "Popravek fotografij in UTF-8 je nameščen. Zaženi aplikacijo in odpri /inventory/manage."
