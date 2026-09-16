async (page) => {
  await page.context().clearCookies();
  await page.goto('http://127.0.0.1:18882');
  await page.evaluate(() => {localStorage.clear();localStorage.setItem('accessToken','synthetic-access');localStorage.setItem('user',JSON.stringify({id:1,nickname:'Security Test',email:'test@example.invalid'}));});
  const googleCalls=[]; const briefingCalls=[];
  page.on('request',r=>{if(r.url().includes('generativelanguage.googleapis.com'))googleCalls.push(r.url());});
  const player={positionAnalysis:{heatmapData:[]},strokeTypes:{smash:1,clear:2,drop:0,drive:0,serve:0,net:0,others:0},abilityMetrics:{aggression:85,rally:70,defense:50,mobility:30,consistency:0},aiCoaching:{feedbackText:''}};
  const report={code:200,message:'test',data:{videoId:77,summary:{myScore:3,opponentScore:2,matchOutcome:'WIN',matchTime:'1:00',totalStrokeCount:3},players:{top:player,bottom:player},hitsData:[]}};
  await page.route('**/api/v1/analysis/77',r=>r.fulfill({json:report}));
  await page.route('**/api/v1/videos/77',r=>r.fulfill({json:{code:200,data:{videoInfo:{videoId:77,title:'Synthetic video'},matchSummary:{matchScore:'2:3',unknownRallies:0,totalRallies:1},timelineEvents:[]}}}));
  let bottomRelease;
  const holdBottom=new Promise(resolve=>{bottomRelease=resolve;});
  await page.route('**/api/v1/videos/77/briefing',async route=>{
    const body=route.request().postDataJSON();briefingCalls.push(body);
    if(Object.keys(body).join(',')!=='player')throw new Error('Unexpected client briefing input');
    if(body.player==='bottom')await holdBottom;
    await route.fulfill({json:{code:200,data:{videoId:77,player:body.player,text:`## 총평\n${body.player.toUpperCase()}_ONLY\n## 핵심 지표\n- Synthetic data\n## 강점\n- Test\n## 보완점\n- Test\n## 추천 훈련\n- Test`}}}).catch(()=>{});
  });
  await page.goto('http://127.0.0.1:18882/report/77');
  await page.getByText('Bottom Player',{exact:true}).first().waitFor();
  await page.getByText('Top Player',{exact:true}).first().click();
  await page.getByText('TOP_ONLY',{exact:true}).first().waitFor();
  bottomRelease();
  if(await page.getByText('BOTTOM_ONLY',{exact:true}).count())throw new Error('Stale bottom result appeared on top selection');
  if(googleCalls.length)throw new Error('Browser contacted provider directly');
  await page.unroute('**/api/v1/analysis/77');
  await page.route('**/api/v1/analysis/77',r=>r.fulfill({status:404,json:{code:404,errorCode:'RESOURCE_NOT_FOUND',message:'영상을 찾을 수 없습니다.'}}));
  await page.reload();
  await page.getByText('영상을 찾을 수 없습니다.',{exact:true}).waitFor();
  if(await page.getByText('분석 준비 중',{exact:false}).count())throw new Error('Foreign video displayed as pending');
  await page.unroute('**/api/v1/analysis/77');
  await page.route('**/api/v1/analysis/77',r=>r.fulfill({status:404,json:{code:404,errorCode:'ANALYSIS_NOT_READY',message:'분석 준비 중'}}));
  await page.reload();
  await page.getByText(/분석.*준비|준비.*분석/).first().waitFor();
  await page.evaluate(result=>{window.securityUiResult=result;},{googleDirectRequests:googleCalls.length,briefingRequests:briefingCalls.length,staleResultBlocked:true,errorStatesSeparated:true});
}
