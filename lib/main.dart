import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';

void main() => runApp(const BattleshipApp());

class BattleshipApp extends StatelessWidget {
  const BattleshipApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Морской бой',
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          scaffoldBackgroundColor: const Color(0xFF08172A),
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF13B8D4),
            brightness: Brightness.dark,
          ),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: const Color(0xFF152B41),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
        home: const BattlePage(),
      );
}

class Ship {
  final List<Point<int>> cells;
  const Ship(this.cells);
  int get length => cells.length;
}

class BattlePage extends StatefulWidget {
  const BattlePage({super.key});

  @override
  State<BattlePage> createState() => _BattlePageState();
}

class _BattlePageState extends State<BattlePage> {
  static const requiredFleet = {4: 1, 3: 2, 2: 3, 1: 4};
  static const sea = Color(0xFF17608E);
  static const shipColor = Color(0xFFBACBD9);
  static const hitColor = Color(0xFFF05A50);
  static const missColor = Color(0xFF5A88A9);
  final nameController = TextEditingController(text: 'Капитан');
  final codeController = TextEditingController();
  final addressController = TextEditingController(text: 'ws://192.168.31.184:9876');
  final String clientId = List.generate(24, (_) => Random.secure().nextInt(16).toRadixString(16)).join();
  WebSocket? socket;
  StreamSubscription<dynamic>? subscription;
  bool connected = false;
  bool connecting = false;
  bool pendingRoom = false;
  String status = 'Подключитесь к серверу';
  String roomId = '';
  String phase = '';
  String opponent = '';
  int playerCount = 0;
  bool ownReady = false;
  bool opponentReady = false;
  bool yourTurn = false;
  bool opponentConnected = false;
  bool youWon = false;
  String winner = '';
  int chosenLength = 4;
  bool horizontal = true;
  final List<Ship> fleet = [];
  Set<Point<int>> ownShips = {};
  Set<Point<int>> incomingShots = {};
  Set<Point<int>> incomingHits = {};
  Set<Point<int>> outgoingShots = {};
  Set<Point<int>> outgoingHits = {};
  Set<Point<int>> enemySunk = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => connect());
  }

  String get playerName => nameController.text.trim().isEmpty ? 'Капитан' : nameController.text.trim();

  void message(String value) {
    if (mounted) setState(() => status = value);
  }

  Future<void> connect() async {
    if (connecting || connected) return;
    final url = addressController.text.trim();
    setState(() {
      connecting = true;
      status = 'Подключение к серверу...';
    });
    try {
      final ws = await WebSocket.connect(url).timeout(const Duration(seconds: 8));
      if (!mounted) {
        await ws.close();
        return;
      }
      socket = ws;
      setState(() {
        connected = true;
        connecting = false;
        status = 'Сервер подключён. Создайте комнату или войдите по коду.';
      });
      subscription = ws.listen(
        onServerMessage,
        onDone: () => onDisconnected(ws, 'Соединение прервано. Нажмите «Повторить». '),
        onError: (Object error) => onDisconnected(ws, 'Ошибка сети: $error'),
        cancelOnError: true,
      );
      if (roomId.isNotEmpty) {
        send({'action': 'join_game', 'clientId': clientId, 'playerName': playerName, 'gameId': roomId});
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        connecting = false;
        connected = false;
        status = 'Нет соединения: $error';
      });
    }
  }

  void onDisconnected(WebSocket ws, String text) {
    if (!mounted || !identical(socket, ws)) return;
    setState(() {
      connected = false;
      connecting = false;
      pendingRoom = false;
      socket = null;
      status = text;
    });
  }

  bool send(Map<String, dynamic> data) {
    if (!connected || socket == null) {
      message('Сначала подключитесь к серверу');
      return false;
    }
    try {
      socket!.add(jsonEncode(data));
      return true;
    } catch (error) {
      message('Не удалось отправить сообщение: $error');
      return false;
    }
  }

  void createRoom() {
    if (pendingRoom) return;
    if (send({'action': 'create_game', 'clientId': clientId, 'playerName': playerName})) {
      setState(() {
        pendingRoom = true;
        status = 'Создаём комнату...';
      });
    }
  }

  void joinRoom() {
    if (pendingRoom) return;
    final code = codeController.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      message('Введите шестизначный код комнаты');
      return;
    }
    if (send({'action': 'join_game', 'clientId': clientId, 'playerName': playerName, 'gameId': code})) {
      setState(() {
        pendingRoom = true;
        status = 'Входим в комнату $code...';
      });
    }
  }

  Set<Point<int>> parseCells(dynamic value) {
    if (value is! List) return {};
    final result = <Point<int>>{};
    for (final item in value) {
      if (item is List && item.length == 2 && item[0] is int && item[1] is int) {
        result.add(Point<int>(item[0] as int, item[1] as int));
      }
    }
    return result;
  }

  void onServerMessage(dynamic raw) {
    try {
      final data = jsonDecode(raw as String);
      if (data is! Map<String, dynamic> || !mounted) return;
      final action = data['action'];
      switch (action) {
        case 'state':
          setState(() {
            pendingRoom = false;
            roomId = (data['gameId'] ?? '').toString();
            codeController.text = roomId;
            phase = (data['phase'] ?? '').toString();
            opponent = (data['opponent'] ?? '').toString();
            playerCount = (data['playerCount'] as num?)?.toInt() ?? 0;
            ownReady = data['ready'] == true;
            opponentReady = data['opponentReady'] == true;
            opponentConnected = data['opponentConnected'] == true;
            yourTurn = data['yourTurn'] == true;
            winner = (data['winner'] ?? '').toString();
            youWon = data['youWon'] == true;
            ownShips = parseCells(data['ownShips']);
            incomingShots = parseCells(data['incomingShots']);
            incomingHits = parseCells(data['incomingHits']);
            outgoingShots = parseCells(data['outgoingShots']);
            outgoingHits = parseCells(data['outgoingHits']);
            enemySunk = parseCells(data['enemySunk']);
            if (ownReady) {
              fleet.clear();
            }
            if (phase == 'waiting') {
              status = 'Комната создана. Ожидаем второго игрока.';
            } else if (phase == 'placing') {
              status = ownReady
                  ? 'Ваш флот готов. ${opponentReady ? 'Ожидаем начала игры.' : 'Противник ещё расставляет корабли.'}'
                  : 'Расставьте корабли на своём поле.';
            } else if (phase == 'playing') {
              status = !opponentConnected
                  ? 'Противник отключён, ждём подключения.'
                  : yourTurn ? 'Ваш ход — выберите клетку поля противника.' : 'Ход противника.';
            } else if (phase == 'finished') {
              status = youWon ? 'Победа! Все корабли противника уничтожены.' : 'Поражение. Противник уничтожил ваш флот.';
            }
          });
          break;
        case 'shot_result':
          message(data['hit'] == true
              ? (data['sunk'] == true ? 'Попадание! Корабль потоплен.' : 'Попадание! Стреляйте снова.')
              : 'Мимо. Теперь ход соперника.');
          break;
        case 'incoming_shot':
          message(data['hit'] == true
              ? (data['sunk'] == true ? 'Противник потопил ваш корабль!' : 'Противник попал в корабль.')
              : 'Противник промахнулся. Ваш ход.');
          break;
        case 'error':
          setState(() {
            pendingRoom = false;
            status = 'Ошибка: ${data['message'] ?? 'неизвестная ошибка'}';
          });
          break;
        case 'room_closed':
          setState(() {
            resetRoom();
            status = (data['message'] ?? 'Комната закрыта').toString();
          });
          break;
      }
    } catch (error) {
      message('Ошибка обработки ответа сервера: $error');
    }
  }

  void resetRoom() {
    roomId = '';
    phase = '';
    opponent = '';
    playerCount = 0;
    pendingRoom = false;
    ownReady = false;
    opponentReady = false;
    yourTurn = false;
    opponentConnected = false;
    youWon = false;
    winner = '';
    fleet.clear();
    ownShips = {};
    incomingShots = {};
    incomingHits = {};
    outgoingShots = {};
    outgoingHits = {};
    enemySunk = {};
  }

  void leaveRoom() {
    if (!connected) {
      setState(() => resetRoom());
      return;
    }
    send({'action': 'leave_game'});
  }

  int countPlaced(int length) => fleet.where((ship) => ship.length == length).length;

  bool canPlace(List<Point<int>> candidate, [List<Ship>? ships]) {
    final existing = (ships ?? fleet).expand((ship) => ship.cells).toSet();
    for (final cell in candidate) {
      if (cell.x < 0 || cell.x >= 10 || cell.y < 0 || cell.y >= 10) return false;
      for (int dx = -1; dx <= 1; dx++) {
        for (int dy = -1; dy <= 1; dy++) {
          if (existing.contains(Point<int>(cell.x + dx, cell.y + dy))) return false;
        }
      }
    }
    return true;
  }

  List<Point<int>> buildShip(int x, int y, int length, bool horizontal) => [
        for (int i = 0; i < length; i++) Point<int>(x + (horizontal ? i : 0), y + (horizontal ? 0 : i)),
      ];

  void placeShipAt(int x, int y) {
    if (phase != 'placing' || ownReady) return;
    final candidate = buildShip(x, y, chosenLength, horizontal);
    if (countPlaced(chosenLength) >= requiredFleet[chosenLength]!) {
      message('Кораблей этой длины уже достаточно');
      return;
    }
    if (!canPlace(candidate)) {
      message('Здесь корабль разместить нельзя: не хватает места или он соприкасается с другим.');
      return;
    }
    setState(() {
      fleet.add(Ship(candidate));
      for (final length in [4, 3, 2, 1]) {
        if (countPlaced(length) < requiredFleet[length]!) {
          chosenLength = length;
          break;
        }
      }
      status = 'Корабль размещён. ${fleet.length} из 10.';
    });
  }

  void undoShip() {
    if (fleet.isEmpty || ownReady) return;
    setState(() {
      final removed = fleet.removeLast();
      chosenLength = removed.length;
      status = 'Последний корабль удалён.';
    });
  }

  void autoFleet() {
    if (ownReady) return;
    final random = Random();
    for (int attempt = 0; attempt < 400; attempt++) {
      final placed = <Ship>[];
      bool success = true;
      for (final length in [4, 3, 3, 2, 2, 2, 1, 1, 1, 1]) {
        bool found = false;
        for (int tries = 0; tries < 300; tries++) {
          final cells = buildShip(random.nextInt(10), random.nextInt(10), length, random.nextBool());
          if (canPlace(cells, placed)) {
            placed.add(Ship(cells));
            found = true;
            break;
          }
        }
        if (!found) {
          success = false;
          break;
        }
      }
      if (success) {
        setState(() {
          fleet..clear()..addAll(placed);
          status = 'Флот расставлен. Нажмите «Готов».';
        });
        return;
      }
    }
    message('Не удалось расставить флот. Попробуйте снова.');
  }

  void ready() {
    if (fleet.length != 10) {
      message('Разместите все 10 кораблей или нажмите «Автофлот».');
      return;
    }
    final cells = fleet.expand((ship) => ship.cells).map((point) => [point.x, point.y]).toList();
    if (send({'action': 'ships_placed', 'ships': cells})) message('Отправляем флот серверу...');
  }

  void shoot(int x, int y) {
    if (phase != 'playing' || !yourTurn || !opponentConnected) return;
    if (outgoingShots.contains(Point<int>(x, y))) {
      message('В эту клетку уже стреляли.');
      return;
    }
    if (send({'action': 'make_move', 'x': x, 'y': y})) message('Выстрел: ${String.fromCharCode(65 + x)}${y + 1}...');
  }

  @override
  void dispose() {
    subscription?.cancel();
    socket?.close();
    nameController.dispose();
    codeController.dispose();
    addressController.dispose();
    super.dispose();
  }

  Widget actionButton(String label, VoidCallback? onPressed, {bool primary = true, IconData? icon}) {
    return SizedBox(
      width: double.infinity,
      child: primary
          ? FilledButton.icon(onPressed: onPressed, icon: Icon(icon ?? Icons.check), label: Text(label))
          : OutlinedButton.icon(onPressed: onPressed, icon: Icon(icon ?? Icons.settings), label: Text(label)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final editing = phase == 'placing' && !ownReady;
    final showBoards = phase == 'placing' || phase == 'playing' || phase == 'finished';
    final placed = fleet.expand((ship) => ship.cells).toSet();
    final myCells = ownReady ? ownShips : placed;
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 25, 16, 76),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.directions_boat, size: 52, color: Colors.cyanAccent),
              const SizedBox(height: 4),
              const Text('МОРСКОЙ БОЙ', textAlign: TextAlign.center, style: TextStyle(fontSize: 27, fontWeight: FontWeight.w800, letterSpacing: 2)),
              const SizedBox(height: 10),
              Row(children: [
                Icon(connected ? Icons.check_circle : Icons.error_outline, color: connected ? Colors.greenAccent : Colors.orangeAccent, size: 19),
                const SizedBox(width: 8),
                Expanded(child: Text(connected ? 'Сервер подключён' : 'Нет соединения', style: const TextStyle(fontSize: 14))),
                if (!connected) TextButton(onPressed: connecting ? null : connect, child: const Text('Повторить')),
              ]),
              if (roomId.isEmpty) ...[
                TextField(controller: addressController, enabled: !connected && !connecting, decoration: const InputDecoration(labelText: 'WebSocket-сервер', prefixIcon: Icon(Icons.dns))),
                const SizedBox(height: 10),
                TextField(controller: nameController, decoration: const InputDecoration(labelText: 'Имя игрока', prefixIcon: Icon(Icons.person))),
                const SizedBox(height: 10),
                TextField(controller: codeController, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Код комнаты для входа', prefixIcon: Icon(Icons.tag))),
                const SizedBox(height: 16),
                actionButton('СОЗДАТЬ ИГРУ', connected && !pendingRoom ? createRoom : null, icon: Icons.add),
                actionButton('ВОЙТИ В ИГРУ', connected && !pendingRoom ? joinRoom : null, primary: false, icon: Icons.login),
              ] else ...[
                Card(color: const Color(0xFF122D45), child: Padding(padding: const EdgeInsets.all(14), child: Column(children: [
                  const Text('КОМНАТА', style: TextStyle(color: Colors.white70)),
                  SelectableText(roomId, style: const TextStyle(fontSize: 30, fontWeight: FontWeight.bold, color: Colors.cyanAccent)),
                  Text('Игроков: $playerCount/2${opponent.isNotEmpty ? '  •  Соперник: $opponent' : ''}', textAlign: TextAlign.center),
                ]))),
                if (editing) ...[
                  const SizedBox(height: 12),
                  const Text('РАССТАНОВКА ФЛОТА', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 5),
                  Row(children: [
                    const Text('Корабль:  '),
                    DropdownButton<int>(value: chosenLength, dropdownColor: const Color(0xFF24445B), items: [4, 3, 2, 1].map((length) => DropdownMenuItem(value: length, child: Text('$length клетки (${countPlaced(length)}/${requiredFleet[length]})'))).toList(), onChanged: (value) { if (value != null) setState(() => chosenLength = value); }),
                  ]),
                  Row(children: [
                    Expanded(child: OutlinedButton.icon(onPressed: () => setState(() => horizontal = !horizontal), icon: const Icon(Icons.rotate_right), label: Text(horizontal ? 'Горизонтально' : 'Вертикально'))),
                    const SizedBox(width: 8),
                    Expanded(child: OutlinedButton.icon(onPressed: undoShip, icon: const Icon(Icons.undo), label: const Text('Отменить'))),
                  ]),
                  const Text('Нажмите на поле, чтобы поставить корабль. Корабли не должны касаться друг друга.', style: TextStyle(color: Colors.white70, fontSize: 12)),
                ],
                if (showBoards) ...[
                  const SizedBox(height: 15),
                  const Text('ВАШЕ ПОЛЕ', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  buildBoard(ships: myCells, shots: incomingShots, hits: incomingHits, onTap: editing ? placeShipAt : null),
                  const SizedBox(height: 12),
                  if (editing) ...[
                    Text('Кораблей размещено: ${fleet.length}/10', textAlign: TextAlign.center),
                    actionButton('АВТОФЛОТ', autoFleet, primary: false, icon: Icons.auto_awesome),
                    actionButton('ГОТОВ', fleet.length == 10 ? ready : null, icon: Icons.check_circle),
                  ],
                  if (phase == 'placing' && ownReady) const Text('Флот подтверждён. Ждём соперника.', textAlign: TextAlign.center),
                  if (phase == 'playing' || phase == 'finished') ...[
                    const SizedBox(height: 18),
                    const Text('ПОЛЕ ПРОТИВНИКА', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    buildBoard(ships: enemySunk, shots: outgoingShots, hits: outgoingHits, sunk: enemySunk, onTap: phase == 'playing' && yourTurn && opponentConnected ? shoot : null),
                    const SizedBox(height: 9),
                    Text(phase == 'finished' ? (youWon ? 'ПОБЕДА!' : 'ПОРАЖЕНИЕ') : (yourTurn ? 'ВАШ ХОД' : 'ХОД СОПЕРНИКА'), textAlign: TextAlign.center, style: TextStyle(color: yourTurn || youWon ? Colors.greenAccent : Colors.amberAccent, fontSize: 18, fontWeight: FontWeight.bold)),
                  ],
                ],
                const SizedBox(height: 14),
                actionButton('ПОКИНУТЬ КОМНАТУ', leaveRoom, primary: false, icon: Icons.logout),
              ],
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: const Color(0xFF17314A), borderRadius: BorderRadius.circular(12)),
                child: Text(status, textAlign: TextAlign.center),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget buildBoard({
    required Set<Point<int>> ships,
    required Set<Point<int>> shots,
    required Set<Point<int>> hits,
    Set<Point<int>> sunk = const {},
    void Function(int x, int y)? onTap,
  }) {
    return LayoutBuilder(builder: (context, constraints) {
      final size = min(constraints.maxWidth, 450.0);
      return Center(child: SizedBox(width: size, child: Column(children: [
        Row(children: [const SizedBox(width: 23), ...List.generate(10, (x) => Expanded(child: Center(child: Text(String.fromCharCode(65 + x), style: const TextStyle(fontSize: 10, color: Colors.white70)))))]),
        const SizedBox(height: 3),
        ...List.generate(10, (y) => Row(children: [
          SizedBox(width: 23, child: Text('${y + 1}', style: const TextStyle(fontSize: 10, color: Colors.white70))),
          ...List.generate(10, (x) {
            final cell = Point<int>(x, y);
            final shot = shots.contains(cell);
            final hit = hits.contains(cell);
            final isShip = ships.contains(cell);
            final isSunk = sunk.contains(cell);
            final color = hit ? hitColor : shot ? missColor : isShip ? shipColor : sea;
            return Expanded(child: AspectRatio(aspectRatio: 1, child: Padding(
              padding: const EdgeInsets.all(1.25),
              child: Material(color: color, borderRadius: BorderRadius.circular(3), child: InkWell(
                onTap: onTap == null ? null : () => onTap(x, y),
                borderRadius: BorderRadius.circular(3),
                child: Center(child: Text(hit ? '✕' : shot ? '•' : isSunk ? '✕' : '', style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.bold))),
              )),
            )));
          }),
        ])),
      ])));
    });
  }
}
