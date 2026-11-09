// Formatage des montants : « 12 000 FCFA » (espace fine insécable, sans décimales).

String formatXaf(int amount) {
  final negative = amount < 0;
  final digits = amount.abs().toString();
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write(' ');
    buf.write(digits[i]);
  }
  return '${negative ? '-' : ''}$buf FCFA';
}

const conditionLabels = {
  'new': 'Neuf',
  'very_good': 'Très bon état',
  'good': 'Bon état',
  'fair': 'Satisfaisant',
};
