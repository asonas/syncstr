// Run in a computer-use Node session after focusing the scaffold's Search field.
export async function reproduceB3(sky, window) {
  const before = await sky.get_window_state({
    window, include_screenshot: false, include_text: true,
  });
  if (!before.accessibility?.focused_element?.includes("Search tracks")) {
    throw new Error("Focus the scaffold's Search field before running the repro");
  }
  for (const key of ["Escape", "Escape", "Control_L+a", "BackSpace"]) {
    await sky.press_key({ window, key });
  }
  for (const key of "kyouhaiitenki") {
    await sky.press_key({ window, key });
  }
  for (const key of ["space", "Left", "space"]) {
    await sky.press_key({ window, key });
  }
  await sky.get_window_state({ window, include_screenshot: false, include_text: true });
  return sky.get_window_state({ window, include_screenshot: true, include_text: true });
}
