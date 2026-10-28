"""Pick the external USB webcam instead of the laptop's built-in one (Windows DirectShow device names)."""
SKIP = ("integrated", "built-in", "builtin", "virtual", "ir camera", "infrared")
PREFER = ("razer", "kiyo")


def list_cameras():
    try:
        from pygrabber.dshow_graph import FilterGraph      # pip install pygrabber
        return FilterGraph().get_input_devices()
    except Exception:
        return []


def find_camera():
    names = list_cameras()
    if not names:
        print("Camera names unavailable (pip install pygrabber); using camera 0. Override with --camera N.")
        return 0
    low = [n.lower() for n in names]
    pick = next((i for i, n in enumerate(low) if any(p in n for p in PREFER)), None)
    if pick is None:
        pick = next((i for i, n in enumerate(low) if not any(s in n for s in SKIP)), 0)
    print(f"Using camera {pick}: {names[pick]}   (all: {', '.join(f'{i}={n}' for i, n in enumerate(names))})")
    return pick
