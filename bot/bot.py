import asyncio
import io
import json
import logging
import os
import re

import qrcode
from aiogram import BaseMiddleware, Bot, Dispatcher, F
from aiogram.filters import Command, CommandObject
from aiogram.types import (
    BufferedInputFile,
    CallbackQuery,
    InlineKeyboardButton,
    InlineKeyboardMarkup,
    Message,
)

PEERCTL = os.environ.get("PEERCTL", "/usr/local/sbin/awg-peerctl")
NAME_RE = re.compile(r"^[A-Za-z0-9_-]{1,32}$")

log = logging.getLogger("awg-bot")


class PeerctlError(Exception):
    pass


async def peerctl(*args: str) -> str:
    proc = await asyncio.create_subprocess_exec(
        "sudo", "-n", PEERCTL, *args,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
    )
    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout=30)
    except asyncio.TimeoutError:
        proc.kill()
        raise PeerctlError("timeout")
    if proc.returncode != 0:
        raise PeerctlError(err.decode().strip() or "unknown error")
    return out.decode()


class AdminOnly(BaseMiddleware):
    """Drop every update that does not come from an allowed Telegram user."""

    def __init__(self, admin_ids: set[int]):
        self.admin_ids = admin_ids

    async def __call__(self, handler, event, data):
        user = data.get("event_from_user")
        if user is None or user.id not in self.admin_ids:
            log.warning("ignored update from %s", user.id if user else None)
            return None
        return await handler(event, data)


def human(n: int) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024:
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} TB"


def ago(sec) -> str:
    if sec is None:
        return "никогда"
    if sec < 90:
        return "онлайн"
    if sec < 3600:
        return f"{sec // 60} мин назад"
    if sec < 86400:
        return f"{sec // 3600} ч назад"
    return f"{sec // 86400} дн назад"


HELP = (
    "Управление профилями VPN.\n\n"
    "/new <имя> — создать профиль (файл и QR-код)\n"
    "/delete <имя> — удалить профиль\n"
    "/list — список профилей\n\n"
    "Имя: латиница, цифры, _ и -, до 32 символов."
)

dp = Dispatcher()


@dp.message(Command("start", "help"))
async def on_help(m: Message):
    await m.answer(HELP)


@dp.message(Command("new"))
async def on_new(m: Message, command: CommandObject):
    name = (command.args or "").strip()
    if not NAME_RE.match(name):
        await m.answer("Укажите имя: /new phone\nДопустимы латиница, цифры, _ и -.")
        return
    try:
        conf = await peerctl("add", name)
    except PeerctlError as e:
        await m.answer(f"Не получилось: {e}")
        return

    await m.answer_document(
        BufferedInputFile(conf.encode(), filename=f"{name}.conf"),
        caption=(
            f"Профиль «{name}» создан. В файле приватный ключ: "
            "не пересылайте его и удалите это сообщение после импорта."
        ),
    )
    try:
        img = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_L, box_size=6, border=2)
        img.add_data(conf)
        img.make(fit=True)
        buf = io.BytesIO()
        img.make_image().save(buf, format="PNG")
        await m.answer_photo(BufferedInputFile(buf.getvalue(), filename=f"{name}.png"),
                             caption="QR-код для телефона")
    except Exception:
        log.exception("QR generation failed")
        await m.answer("QR-код создать не удалось, используйте файл.")


@dp.message(Command("list"))
async def on_list(m: Message):
    try:
        peers = json.loads(await peerctl("list"))
    except (PeerctlError, ValueError) as e:
        await m.answer(f"Не получилось: {e}")
        return
    if not peers:
        await m.answer("Профилей нет.")
        return
    lines = [
        f"• {p['name']} ({p['ip']}) — {ago(p['last_seen_sec'])}, "
        f"↓{human(p['tx'])} ↑{human(p['rx'])}"
        for p in peers
    ]
    await m.answer(f"Профилей: {len(peers)}\n" + "\n".join(lines))


@dp.message(Command("delete"))
async def on_delete(m: Message, command: CommandObject):
    name = (command.args or "").strip()
    if not NAME_RE.match(name):
        await m.answer("Укажите имя: /delete phone")
        return
    kb = InlineKeyboardMarkup(inline_keyboard=[[
        InlineKeyboardButton(text="Удалить", callback_data=f"del:{name}"),
        InlineKeyboardButton(text="Отмена", callback_data="cancel"),
    ]])
    await m.answer(f"Удалить профиль «{name}»? Он перестанет работать сразу.", reply_markup=kb)


@dp.callback_query(F.data.startswith("del:"))
async def on_confirm_delete(c: CallbackQuery):
    name = c.data.split(":", 1)[1]
    try:
        await peerctl("del", name)
        text = f"Профиль «{name}» удалён."
    except PeerctlError as e:
        text = f"Не получилось: {e}"
    await c.message.edit_text(text)
    await c.answer()


@dp.callback_query(F.data == "cancel")
async def on_cancel(c: CallbackQuery):
    await c.message.edit_text("Отменено.")
    await c.answer()


async def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    token = os.environ.get("BOT_TOKEN", "").strip()
    admins = {int(x) for x in os.environ.get("ADMIN_IDS", "").replace(" ", "").split(",") if x}
    if not token or not admins:
        raise SystemExit("BOT_TOKEN and ADMIN_IDS must be set")

    dp.message.outer_middleware(AdminOnly(admins))
    dp.callback_query.outer_middleware(AdminOnly(admins))
    await dp.start_polling(Bot(token))


if __name__ == "__main__":
    asyncio.run(main())
