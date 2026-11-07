// Google Maps notification fallback: classify an instruction into the
// firmware's built-in DirectionTurn arrow (0x01-0x0b). The walking navigator
// picks its arrows in walknav/maneuver_plan.dart instead.

// ---------------------------------------------------------------------------
// Manoeuvre classification
// ---------------------------------------------------------------------------

/// Normalised manoeuvre types, mapped to the firmware's DirectionTurn byte.
enum ManoeuvreType {
  straightDot(0x01), // destination marker
  straight(0x02),
  right(0x03),
  left(0x04),
  slightRight(0x05),
  slightLeft(0x06),
  sharpRight(0x07),
  sharpLeft(0x08),
  uTurnLeft(0x09),
  uTurnRight(0x0a),
  merge(0x0b),
  unknown(0x02); // fallback to straight (real-world: unclassified = go forward)

  const ManoeuvreType(this.directionTurnByte);

  /// The DirectionTurn byte used in the TRIP_STATUS packet.
  final int directionTurnByte;
}

/// Classify a navigation instruction into a [ManoeuvreType].
///
/// Checks [navIconSource] first (the notification icon-extra key name), then
/// falls back to parsing [instructionText] (turnDistance / road name fields)
/// for direction keywords.
ManoeuvreType classifyManoeuvre({
  String navIconSource = '',
  String instructionText = '',
}) {
  // Combine both sources — navIconSource rarely contains direction words
  // (it's usually "android.ongoingActivityNoti.chipIcon"), but instructionText
  // from Google Maps contains "Turn left", "Continue straight", etc.
  final lower = '$navIconSource $instructionText'.toLowerCase();

  return _classifyFromText(lower);
}

ManoeuvreType _classifyFromText(String lower) {
  // U-turn (check before left/right to avoid false matches)
  if (lower.contains('u-turn') || lower.contains('uturn')) {
    if (lower.contains('right')) return ManoeuvreType.uTurnRight;
    return ManoeuvreType.uTurnLeft;
  }

  // Arrive / destination
  if (lower.contains('arrive') || lower.contains('destination')) {
    return ManoeuvreType.straightDot;
  }

  // Sharp turns
  if (lower.contains('sharp')) {
    if (lower.contains('left')) return ManoeuvreType.sharpLeft;
    return ManoeuvreType.sharpRight;
  }

  // Slight turns
  if (lower.contains('slight') || lower.contains('fork')) {
    if (lower.contains('left')) return ManoeuvreType.slightLeft;
    return ManoeuvreType.slightRight;
  }

  // Merge
  if (lower.contains('merge') || lower.contains('ramp')) {
    return ManoeuvreType.merge;
  }

  // Roundabout — treat as the exit direction if determinable, else right
  if (lower.contains('roundabout')) {
    if (lower.contains('left')) return ManoeuvreType.left;
    if (lower.contains('straight')) return ManoeuvreType.straight;
    return ManoeuvreType.right;
  }

  // "Turn left", "Turn right", "Keep left", "Keep right"
  if (lower.contains('left')) return ManoeuvreType.left;
  if (lower.contains('right')) return ManoeuvreType.right;

  // Straight / continue / towards / head / proceed
  if (lower.contains('straight') ||
      lower.contains('continue') ||
      lower.contains('towards') ||
      lower.contains('head') ||
      lower.contains('proceed')) {
    return ManoeuvreType.straight;
  }

  return ManoeuvreType.unknown;
}
