"""Contact-time estimate for both legacy and extended impact recordings."""


def impact_time(clip):
    # New firmware reports its trigger age before sending the audio payload.
    # Old sessions only have the payload receive time and use the original lag.
    value = clip.get("impact_t_s")
    return float(value) if value not in (None, "") else float(clip["t_s"]) - 0.08
