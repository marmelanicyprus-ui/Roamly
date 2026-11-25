import 'package:flutter/material.dart';

import '../app_state.dart';

/// Первый запуск: имя. Вход через Google, Apple ID, Яндекс ID — в следующих сборках.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _go() {
    if (_name.text.trim().isEmpty) return;
    App.read(context).setName(_name.text);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              Icon(Icons.sailing_outlined, size: 64, color: cs.primary),
              const SizedBox(height: 16),
              Text('Roamly offline',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text('Поездки, общие расходы и связь с группой — даже без интернета.',
                  textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant)),
              const SizedBox(height: 32),
              TextField(
                controller: _name,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Как вас зовут'),
                onSubmitted: (_) => _go(),
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: _go, child: const Text('Начать')),
              const Spacer(),
              Text('Тестовая сборка · данные хранятся только на этом телефоне',
                  textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }
}
