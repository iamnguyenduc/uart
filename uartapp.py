import serial
import time
import struct
import os
import threading
from datetime import datetime
import tkinter as tk
from tkinter import ttk, filedialog, messagebox

PORT = "COM5"
BAUD = 9600

gap_word  = 0.005
gap_frame = 0.5
rx_timeout_s = 0.2

LOG_FILE = "uart_log.txt"


def ts_now() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]


def parse_hex32(s: str) -> int:
    s = s.strip().replace("_", "").replace(" ", "")
    if not s:
        raise ValueError("empty")
    if s.startswith("#"):
        raise ValueError("comment")
    if s.lower().startswith("0x"):
        s = s[2:]
    v = int(s, 16)
    if not (0 <= v <= 0xFFFFFFFF):
        raise ValueError("out of range 0..FFFFFFFF")
    return v


def read_exact(ser: serial.Serial, n: int, timeout_s: float) -> bytes:
    t0 = time.perf_counter()
    buf = b""
    while len(buf) < n and (time.perf_counter() - t0) < timeout_s:
        chunk = ser.read(n - len(buf))
        if chunk:
            buf += chunk
        else:
            time.sleep(0.001)
    return buf


class App(tk.Tk):
    def clear_log(self):
        # 1) Xoá log hiển thị trên UI
        self.log_text.delete("1.0", "end")

        # 2) (Tuỳ chọn) xoá luôn file log
        # Nếu đang chạy thì nên dừng trước để tránh ghi lại ngay lập tức
        try:
            with open(LOG_FILE, "w", encoding="utf-8") as f:
                f.write("")  # truncate file
        except Exception as e:
            messagebox.showerror("Lỗi", f"Không xoá được file log: {e}")
            return

        self.append_log(f"{ts_now()} | LOG CLEARED")

    def __init__(self):
        super().__init__()
        self.title("UART Sender")
        self.geometry("990x650")

        self.words: list[int] = []
        self.stop_flag = threading.Event()
        self.worker: threading.Thread | None = None

        self._build_ui()

    def _build_ui(self):
        top = ttk.Frame(self, padding=10)
        top.pack(fill="x")

        # COM/BAUD
        ttk.Label(top, text="PORT:").grid(row=0, column=0, sticky="w")
        self.port_var = tk.StringVar(value=PORT)
        ttk.Entry(top, textvariable=self.port_var, width=10).grid(row=0, column=1, sticky="w", padx=(5, 15))

        ttk.Label(top, text="BAUD:").grid(row=0, column=2, sticky="w")
        self.baud_var = tk.IntVar(value=BAUD)
        ttk.Entry(top, textvariable=self.baud_var, width=10).grid(row=0, column=3, sticky="w", padx=(5, 15))

        # Buttons import
        ttk.Button(top, text="Nhập từ bàn phím", command=self.open_manual_input).grid(row=0, column=4, padx=5)
        ttk.Button(top, text="Import từ file .txt", command=self.import_from_file).grid(row=0, column=5, padx=5)

        # Start/Stop
        ttk.Button(top, text="Start", command=self.start).grid(row=0, column=6, padx=(20, 5))
        ttk.Button(top, text="Stop", command=self.stop).grid(row=0, column=7, padx=5)

        # Listbox words
        mid = ttk.Frame(self, padding=10)
        mid.pack(fill="both", expand=True)

        left = ttk.Frame(mid)
        left.pack(side="left", fill="y")

        ttk.Label(left, text="Danh sách mã (HEX 32-bit):").pack(anchor="w")
        self.listbox = tk.Listbox(left, width=28, height=18)
        self.listbox.pack(fill="y", pady=5)

        ttk.Button(left, text="Xoá mã đang chọn", command=self.delete_selected).pack(fill="x", pady=(5, 0))
        ttk.Button(left, text="Xoá tất cả", command=self.clear_all).pack(fill="x", pady=5)

        # Log viewer
        right = ttk.Frame(mid)
        right.pack(side="left", fill="both", expand=True, padx=(15, 0))

        ttk.Label(right, text="Log:").pack(anchor="w")
        self.log_text = tk.Text(right, wrap="none")
        self.log_text.pack(fill="both", expand=True)

        bottom = ttk.Frame(self, padding=(10, 0, 10, 10))
        bottom.pack(fill="x")
        ttk.Label(bottom, text=f"Log file: {LOG_FILE}").pack(anchor="w")
        # clear LOG
        ttk.Button(top, text="Clear LOG", command=self.clear_log).grid(row=0, column=8, padx=5)

    def append_log(self, line: str):
        # chạy trong main thread
        self.log_text.insert("end", line + "\n")
        self.log_text.see("end")

    def refresh_listbox(self):
        self.listbox.delete(0, "end")
        for w in self.words:
            self.listbox.insert("end", f"0x{w:08X}")

    def open_manual_input(self):
        win = tk.Toplevel(self)
        win.title("Nhập mã (mỗi dòng 1 mã)")
        win.geometry("450x400")

        ttk.Label(win, text="Nhập HEX. Mỗi dòng 1 mã:").pack(anchor="w", padx=10, pady=10)
        txt = tk.Text(win, height=12)
        txt.pack(fill="both", expand=True, padx=10)

        def add_codes():
            raw = txt.get("1.0", "end").splitlines()
            new_words = []
            for line in raw:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                try:
                    new_words.append(parse_hex32(line))
                except Exception as e:
                    messagebox.showerror("Lỗi", f"Sai dòng: '{line}'\n{e}")
                    return
            if not new_words:
                messagebox.showwarning("Thông báo", "Không có mã hợp lệ.")
                return
            self.words.extend(new_words)
            self.refresh_listbox()
            win.destroy()

        ttk.Button(win, text="Thêm vào danh sách", command=add_codes).pack(pady=10)

    def import_from_file(self):
        path = filedialog.askopenfilename(
            title="Chọn file .txt",
            filetypes=[("Text files", "*.txt"), ("All files", "*.*")]
        )
        if not path:
            return
        try:
            new_words = []
            with open(path, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#"):
                        continue
                    new_words.append(parse_hex32(line))
            if not new_words:
                raise ValueError("File không có mã hợp lệ.")
            self.words.extend(new_words)
            self.refresh_listbox()
        except Exception as e:
            messagebox.showerror("Lỗi import", str(e))

    def delete_selected(self):
        sel = self.listbox.curselection()
        if not sel:
            return
        idx = sel[0]
        del self.words[idx]
        self.refresh_listbox()

    def clear_all(self):
        self.words.clear()
        self.refresh_listbox()

    def start(self):
        if self.worker and self.worker.is_alive():
            messagebox.showinfo("Đang chạy", "Chương trình đang chạy!")
            return
        if not self.words:
            messagebox.showwarning("Thiếu dữ liệu", "Dữ liệu trống!")
            return

        self.stop_flag.clear()
        self.worker = threading.Thread(target=self.run_uart_loop, daemon=True)
        self.worker.start()
        self.append_log(f"{ts_now()} | START")

    def stop(self):
        self.stop_flag.set()
        self.append_log(f"{ts_now()} | STOP requested")

    def run_uart_loop(self):
        port = self.port_var.get().strip()
        baud = int(self.baud_var.get())

        try:
            with serial.Serial(port, baud, timeout=0) as ser, open(LOG_FILE, "a", encoding="utf-8") as log:
                time.sleep(0.2)
                round_idx = 0

                while not self.stop_flag.is_set():
                    round_idx += 1
                    for i, w in enumerate(list(self.words)):  # copy để tránh sửa list khi đang chạy
                        if self.stop_flag.is_set():
                            break

                        tx = struct.pack(">I", w)
                        tx_hex = tx.hex().upper()

                        ser.reset_input_buffer()
                        ser.write(tx)
                        ## cap nhat LOG TX | RX1 | RX2 | ST1 | ST2 | PASS1 | PASS2
                        rx = read_exact(ser, 14, timeout_s=rx_timeout_s)
                        rx_hex = rx.hex().upper()

                        if len(rx) != 14:
                            line = f"{ts_now()} | R={round_idx} I={i} | TX={tx_hex} | RX={rx_hex} | SHORT len={len(rx)}"
                        else:
                            echo_tx = rx[0:4]
                            rx1 = rx[4:8]
                            rx2 = rx[8:12]
                            st1 = rx[12:13]
                            st2 = rx[13:14]

                            echo_hex = echo_tx.hex().upper()
                            rx1_hex = rx1.hex().upper()
                            rx2_hex = rx2.hex().upper()

                            st1_chr = st1.decode(errors="replace")
                            st2_chr = st2.decode(errors="replace")

                            pass1 = (st1 == b'K')
                            pass2 = (st2 == b'K')

                            line = (
                                f"{ts_now()} | R={round_idx} I={i} | "
                                f"TX={tx_hex} | ECHO={echo_hex} | "
                                f"RX1={rx1_hex} | RX2={rx2_hex} | "
                                f"ST1={st1_chr} | ST2={st2_chr} | "
                                f"{'PASS1' if pass1 else 'FAIL1'} | {'PASS2' if pass2 else 'FAIL2'}"
                            )

                        log.write(line + "\n")
                        log.flush()

                        # đẩy log lên UI (main thread)
                        self.after(0, self.append_log, line)

                        time.sleep(gap_word)

                    time.sleep(gap_frame)

            self.after(0, self.append_log, f"{ts_now()} | STOPPED")
        except Exception as e:
            self.after(0, self.append_log, f"{ts_now()} | ERROR: {e}")
            self.after(0, messagebox.showerror, "Lỗi UART", str(e))


if __name__ == "__main__":

    app = App()
    app.mainloop()
