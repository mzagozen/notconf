import logging
import pathlib
import signal
import threading

import argparse
import libyang
import sysrepo

logging.basicConfig(level=logging.DEBUG, format="[%(levelname)s] %(message)s")
sysrepo.configure_logging(py_logging=True)
libyang.configure_logging(enable_py_logger=True)

def load_data(stop, files):
    with sysrepo.SysrepoConnection() as conn:
        with conn.start_session("operational") as sess:
            with conn.get_ly_ctx() as ctx:
                for file_oper in files:
                    logging.debug(f"opening {file_oper}")
                    with open(file_oper) as f:
                        data = ctx.parse_data_file(f, "xml", parse_only=True)
                    sess.edit_batch_ly(data)
                    sess.apply_changes()
            spam = 0
            while not stop.wait(1):
                if spam % 60 == 0:
                    logging.debug("keeping session alive")
                spam += 1

def main():
    parser = argparse.ArgumentParser()
    g = parser.add_mutually_exclusive_group()
    g.add_argument("--path", default="/yang-modules/operational/")
    g.add_argument("--file")
    args = parser.parse_args()
    if args.path:
        search_path = pathlib.Path(args.path)
        files = sorted(search_path.glob("*.xml"))
        logging.info(f"XML files found in {search_path}: {', '.join(str(f) for f in files)}")
    else:
        files = [args.file]

    stop = threading.Event()
    t = threading.Thread(target=load_data, args=(stop, files))
    t.start()
    signal.sigwait({signal.SIGINT, signal.SIGTERM})
    stop.set()
    t.join()

if __name__ == "__main__":
    main()
