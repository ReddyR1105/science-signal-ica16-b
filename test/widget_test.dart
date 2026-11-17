import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:science_signal/trivia.dart';
void main(){
 final body=File('evidence/t02.json').readAsStringSync();
 test('T02 decoded live response contains five validated questions',(){
 final rows=parseQuestions(body);expect(rows.length,5);expect(rows[2].text,"In the periodic table, Potassium's symbol is the letter K.");
 });
 test('T03 reject malformed encoding, status codes and short sets',() async{
 for(final mutate in <void Function(Map)>[
 (d)=>d['results'][0]['question']='bad%2G',
 (d)=>d['response_code']=3,
 (d)=>d['response_code']=0.0,
 (d)=>d['results'].removeLast(),
 (d)=>d['results'][0]['question']='%20',
 ]){final d=jsonDecode(body) as Map;mutate(d);expect(()=>parseQuestions(jsonEncode(d)),throwsFormatException);}
 int calls=0;
 final api=Trivia(get:(uri)async {calls++;expect(uri.toString(),endpoint);return http.Response('bad',503);});
 await expectLater(api.fetch(),throwsFormatException);await expectLater(api.fetch(),throwsFormatException);expect(calls,1);
 });
 test('T04 T05 answer locking, review score and fresh round',(){
 final questions=parseQuestions(body);final r=Round('a',questions);
 for(var i=0;i<5;i++){expect(r.advance(),false);final choice=i.isEven?questions[i].answer:!questions[i].answer;r.choose(choice);r.choose(!choice);expect(r.choices.last,choice);expect(r.advance(),i==4);}
 expect(r.score,3);expect(r.choices.length,5);final replay=Round('b',questions);expect(replay.score,0);expect(replay.choices,isEmpty);expect(replay.id,isNot(r.id));
 });
}

