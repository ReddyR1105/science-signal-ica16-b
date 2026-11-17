import 'dart:convert';
import 'package:http/http.dart' as http;

const endpoint = 'https://opentdb.com/api.php?amount=5&category=17&difficulty=medium&type=boolean&encode=url3986';
class Question {
  final String text;
  final bool answer;
  const Question(this.text, this.answer);
}
String decoded(dynamic value) {
  if(value is! String || value.trim().isEmpty) throw const FormatException('Missing question or answer.');
  try { return Uri.decodeComponent(value).trim(); } catch (_) { throw const FormatException('Invalid URL encoding.'); }
}
List<Question> parseQuestions(String body) {
  final data=jsonDecode(body);
  if(data is! Map || data['response_code'] != 0) throw const FormatException('Trivia service rejected the request.');
  final rows=data['results'];
  if(rows is! List || rows.length!=5) throw const FormatException('Expected exactly five questions.');
  return rows.map((row){
    if(row is! Map || decoded(row['category'])!='Science & Nature' || decoded(row['type'])!='boolean' || decoded(row['difficulty'])!='medium') throw const FormatException('Unexpected question category, difficulty or type.');
    final other=row['incorrect_answers'];
    final right=decoded(row['correct_answer']);
    final text=decoded(row['question']);
    if(text.isEmpty || other is! List || other.length!=1 || !({'True','False'}.containsAll([right,decoded(other.single)])) || right==decoded(other.single)) throw const FormatException('Invalid boolean question.');
    return Question(text,right=='True');
  }).toList(growable:false);
}
class Trivia {
  final Future<http.Response> Function(Uri) get;
  final Stopwatch clock=Stopwatch()..start();
  Duration? last;
  Trivia({this.get=http.get});
  Future<List<Question>> fetch() async {
    if(last!=null && clock.elapsed-last! < const Duration(seconds:5)) throw const FormatException('Wait five seconds between requests.');
    last=clock.elapsed;
    final r=await get(Uri.parse(endpoint)).timeout(const Duration(seconds:10));
    if(r.statusCode!=200) throw FormatException('Trivia service returned HTTP ${r.statusCode}.');
    return parseQuestions(r.body);
  }
}
class Round {
  final String id;
  final List<Question> questions;
  final List<bool> _choices=[];
  int index=0;
  Round(this.id,this.questions);
  List<bool> get choices=>List.unmodifiable(_choices);
  bool get answered=>_choices.length>index;
  void choose(bool value){if(!answered && index<questions.length) _choices.add(value);}
  bool advance(){if(!answered)return false; if(index==questions.length-1)return true;index++;return false;}
  int get score=>[for(var i=0;i<_choices.length;i++) if(_choices[i]==questions[i].answer) i].length;
}

