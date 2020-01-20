import 'dart:async';
import 'dart:convert';

import 'message.dart';
import 'channel.dart';

typedef JoinHandler = void Function(
  String key,
  dynamic current,
  dynamic joined,
);
typedef LeaveHandler = void Function(
  String key,
  dynamic current,
  dynamic left,
);

class PhoenixPresence {
  final PhoenixChannel channel;
  StreamSubscription _subscription;
  final Map<String, String> eventNames;
  Map<String, dynamic> state = {};
  List pendingDiffs = [];

  String _joinRef;

  JoinHandler _joinHandler = (a, b, c) {};
  LeaveHandler _leaveHandler = (a, b, c) {};
  Function() _syncHandler = () {};

  PhoenixPresence({this.channel, this.eventNames}) {
    Set<String> eventNames = {stateEventName, diffEventName};
    _subscription = channel.messages
        .where((Message message) => eventNames.contains(message.event))
        .listen(_onMessage);
  }

  void onJoin(JoinHandler joinHandler) {
    _joinHandler = joinHandler;
  }

  void onLeave(LeaveHandler leaveHandler) {
    _leaveHandler = leaveHandler;
  }

  void onSync(Function() syncHandler) {
    _syncHandler = syncHandler;
  }

  bool get inPendingSyncState =>
      _joinRef == null || _joinRef != channel.joinRef;

  String get stateEventName {
    if (eventNames.containsKey('state')) return eventNames['state'];
    return 'presence_state';
  }

  String get diffEventName {
    if (eventNames.containsKey('diff')) return eventNames['diff'];
    return 'presence_diff';
  }

  List<dynamic> list(
    Map<String, dynamic> presences, [
    dynamic Function(String, dynamic) chooser,
  ]) {
    chooser = chooser ?? (k, v) => v;
    return _map(presences, (k, v) => chooser(k, v));
  }

  void dispose() {
    _subscription.cancel();
  }

  void _onMessage(Message message) {
    if (message.event == stateEventName) {
      _joinRef = channel.joinRef;
      var newState = message.payload;
      state = _syncState(state, newState, _joinHandler, _leaveHandler);
      pendingDiffs.forEach((diff) {
        state = _syncDiff(state, diff, _joinHandler, _leaveHandler);
      });
      pendingDiffs = [];
      _syncHandler();
    } else if (message.event == diffEventName) {
      var diff = message.payload;
      if (inPendingSyncState) {
        pendingDiffs.add(diff);
      } else {
        state = _syncDiff(state, diff, _joinHandler, _leaveHandler);
        _syncHandler();
      }
    }
  }
}

Map<String, dynamic> _syncState(
  Map<String, dynamic> currentState,
  Map<String, dynamic> newState,
  JoinHandler onJoin,
  LeaveHandler onLeave,
) {
  Map<String, dynamic> state = _clone(currentState);
  Map<String, dynamic> joins = {};
  Map<String, dynamic> leaves = {};

  _map(state, (key, presence) {
    if (newState.containsKey(key)) {
      leaves[key] = presence;
    }
  });
  _map(newState, (key, newPresence) {
    if (state.containsKey(key)) {
      var currentPresence = state[key];
      var newRefs = (newPresence.metas as List).map((m) => m.phx_ref).toSet();
      var curRefs =
          (currentPresence.metas as List).map((m) => m.phx_ref).toSet();

      var joinedMetas = (newPresence.metas as List)
          .where((m) => !curRefs.contains(m.phx_ref))
          .toList();

      var leftMetas = (currentPresence.metas as List)
          .where((m) => !newRefs.contains(m.phx_ref))
          .toList();

      if (joinedMetas.length > 0) {
        joins[key] = newPresence;
        joins[key].metas = joinedMetas;
      }
      if (leftMetas.length > 0) {
        leaves[key] = _clone(currentPresence);
        leaves[key].metas = leftMetas;
      }
    } else {
      joins[key] = newPresence;
    }
  });
  return _syncDiff(state, {'joins': joins, 'leaves': leaves}, onJoin, onLeave);
}

Map<String, dynamic> _syncDiff(
  Map<String, dynamic> currentState,
  Map<String, dynamic> diff,
  JoinHandler onJoin,
  LeaveHandler onLeave,
) {
  var state = _clone(currentState);

  Map<String, dynamic> joins = diff['joins'];
  Map<String, dynamic> leaves = diff['leaves'];

  _map(joins, (key, newPresence) {
    var currentPresence = state[key];
    state[key] = newPresence;
    if (currentPresence) {
      var joinedRefs = (state[key].metas as List).map((m) => m.phx_ref).toSet();
      var curMetas = (currentPresence.metas as List)
          .where((m) => !joinedRefs.contains(m.phx_ref));
      (state[key].metas as List).insertAll(0, curMetas);
    }
    onJoin(key, currentPresence, newPresence);
  });
  _map(leaves, (key, leftPresence) {
    var currentPresence = state[key];
    if (!currentPresence) return;
    var refsToRemove =
        (leftPresence.metas as List).map((m) => m.phx_ref).toSet();
    currentPresence.metas = (currentPresence.metas as List)
        .where((p) => !refsToRemove.contains(p.phx_ref));
    onLeave(key, currentPresence, leftPresence);
    if (currentPresence.metas.length == 0) {
      state.remove(key);
    }
  });
  return state;
}

List<dynamic> _map(
  Map<String, dynamic> presences,
  dynamic Function(String, dynamic) mapper,
) {
  return presences.entries
      .map((entry) => mapper(entry.key, entry.value))
      .toList();
}

Map<String, dynamic> _clone(Map<String, dynamic> presences) {
  return jsonDecode(jsonEncode(presences));
}
