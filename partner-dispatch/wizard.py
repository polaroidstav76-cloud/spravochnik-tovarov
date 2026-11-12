"""First-run walkthrough. Contains no customer addresses or credentials."""
from tkinter import ttk

STEPS = [
 ('Бот', 'Telegram-бот уже создан',
  'Используем @perezakazi_bot.\n\nВставьте токен, полученный у официального @BotFather, в поле «Токен отдельного бота». Сам токен в переписку отправлять не нужно.\n\nВ боте пока нет ответов: обработчик начнёт отвечать после заполнения доступов и запуска на этом компьютере.',
  [('Ввести токен', 'field:bot_token'),('Проверить бота','bot')]),
 ('Telegram API', 'Доступ к большим файлам',
  'Для файлов до 500 МБ нужны Telegram API ID и API hash.\n\nОткройте my.telegram.org/apps, войдите самостоятельно и выберите API development tools. Название приложения: Cloudshop Print Dispatch. Платформа: Desktop. Описание: приём макетов фотоцентра.\n\nПеренесите api_id и api_hash в настройки программы. Это регистрация приложения; программа входит только как бот и не просит пароль или код вашего личного Telegram.',
  [('Открыть Telegram API','url:https://my.telegram.org/apps'),('Ввести API ID и hash','field:api_id')]),
 ('Яндекс Диск', 'Место для архива',
  'Нужен уже существующий Яндекс Диск со свободным местом. Подписку покупать не требуется.\n\nВ Яндекс OAuth создайте приложение для своего Диска. Redirect URI: https://oauth.yandex.ru/verification_code\nПрава: cloud_api:disk.read, cloud_api:disk.write, cloud_api:disk.info.\n\nСкопируйте ClientID в одноимённое поле, нажмите «Получить токен Диска» и подтвердите доступ на сайте Яндекса. Полученный токен введите только в программе. Можно вставить весь адрес страницы с фрагментом #access_token — программа извлечёт токен локально.\n\nАрхив публикуется по ссылке. Любой получивший ссылку сможет его скачать. На Диске и компьютере должно хватать места.',
  [('Создать приложение Диска','url:https://oauth.yandex.ru/client/new'),('Ввести ClientID и токен','field:disk_client_id'),('Получить токен Диска','oauth')]),
 ('Почта', 'Письмо сначала только вам',
  'Укажите свой Яндекс-адрес в поле отправителя, а свой тестовый адрес — в поле получателя. Адрес не зашит в публичную программу: вводим его только на вашем компьютере.\n\nВ Яндекс ID создайте отдельный пароль приложения для почты. В настройках Почты разрешите доступ почтовых программ и использование паролей приложений.\n\nОсновной пароль от аккаунта не вводите. После заполнения нажмите «Проверить Диск и почту». Эта проверка НЕ отправляет письмо.',
  [('Создать пароль приложения','url:https://id.yandex.ru/security/app-passwords'),('Ввести адреса и пароль','field:sender'),('Проверить Диск и почту','check')]),
 ('Сотрудники', 'Запуск и подключение',
  'Нажмите «Запустить бота», дождитесь сообщения о подключении. Затем откройте «Подключить сотрудников».\n\nСначала отправьте @perezakazi_bot команду /owner с вашим кодом. После этого сотрудникам можно выдать команду /join с отдельным кодом и названием филиала. Код владельца им передавать не нужно.\n\nКнопки главного меню: «Широкоформатная печать» и «ДТФ-печать». ДТФ пока не настроена и не принимает файлы. В широкоформатной печати доступны загрузка, список названий, срочная отправка, удаление и возврат в меню.',
  [('Запустить бота','start'),('Показать команды подключения','pair')]),
 ('Тест', 'Проверка на безопасном макете',
  'Откройте тестовый файл кнопкой ниже и отправьте его боту как документ без сжатия. В боте сначала выберите «Широкоформатная печать».\n\nДождитесь «Сохранён». Проверьте «Просмотр файлов» и «Удалить файл», затем загрузите тест заново и нажмите «Отправить сейчас».\n\nДо подтверждения теста письма имеют пометку ТЕСТ. Проверьте свой ящик и «Спам», скачайте ZIP, распакуйте и откройте TIF. Только после этого нажмите «Тестовое письмо проверено».\n\nПринятие письма SMTP-сервером не доказывает попадание во «Входящие»: эту часть проверяем вручную.',
  [('Показать тестовый TIF','sample'),('Тестовое письмо проверено','confirm')]),
 ('Расписание', 'Переход к ежедневной работе',
  'Ежедневная отправка по умолчанию выключена. Включать её можно только после подтверждённого тестового письма. В окне «Очередь и отправка» отметьте галочку 18:00 МСК.\n\nФайлы, присланные начиная с 18:00, остаются на следующий день. «Отправить сейчас» отправляет текущую очередь выбранного направления раньше расписания.\n\nВключите автозапуск при входе в Windows. Компьютер должен оставаться включённым, с интернетом и без сна до завершения отправки. Закрытие программы останавливает обработчик; сворачивание — нет.\n\nПока получатель ваш тестовый адрес. Почту партнёра поменяем после проверки; при смене доступов или адресов программа отключит расписание до нового теста.',
  [('Открыть очередь','main'),('Настроить автозапуск','autostart'),('Сохранить отчёт без секретов','report')]),
]


class Wizard(ttk.Frame):
    def __init__(self,parent,app):
        super().__init__(parent,padding=16)
        self.app=app
        self.index=min(int(app.q.setting('wizard_step','0')),len(STEPS)-1)
        self.columnconfigure(1,weight=1);self.rowconfigure(1,weight=1)
        self.list=ttk.Treeview(self,show='tree',height=10,selectmode='browse')
        self.list.column('#0',width=160,stretch=False)
        for i,step in enumerate(STEPS):self.list.insert('','end',iid=str(i),text=f'{i+1}. {step[0]}')
        self.list.grid(row=0,column=0,rowspan=4,sticky='ns',padx=(0,18))
        self.list.bind('<<TreeviewSelect>>',self.selected)
        self.heading=ttk.Label(self,font=('Segoe UI',16,'bold'))
        self.heading.grid(row=0,column=1,sticky='w',pady=(0,12))
        self.text=ttk.Label(self,wraplength=660,justify='left',anchor='nw')
        self.text.grid(row=1,column=1,sticky='nsew')
        self.actions=ttk.Frame(self);self.actions.grid(row=2,column=1,sticky='w',pady=14)
        nav=ttk.Frame(self);nav.grid(row=3,column=1,sticky='ew')
        self.previous=ttk.Button(nav,text='← Предыдущий шаг',command=lambda:self.move(-1));self.previous.pack(side='left')
        self.next=ttk.Button(nav,text='Следующий шаг →',command=lambda:self.move(1));self.next.pack(side='right')
        self.show()
    def selected(self,event):
        value=self.list.selection()
        if value and int(value[0])!=self.index:self.index=int(value[0]);self.show()
    def move(self,delta):
        self.index=max(0,min(len(STEPS)-1,self.index+delta));self.show()
    def show(self):
        step=STEPS[self.index];self.app.q.set_setting('wizard_step',self.index)
        self.list.selection_set(str(self.index))
        self.heading.configure(text=f'{self.index+1}. {step[1]}');self.text.configure(text=step[2])
        for child in self.actions.winfo_children():child.destroy()
        for title,action in step[3]:ttk.Button(self.actions,text=title,command=lambda a=action:self.app.wizard_action(a)).pack(side='left',padx=(0,7))
        self.previous.configure(state='disabled' if self.index==0 else 'normal')
        self.next.configure(state='disabled' if self.index==len(STEPS)-1 else 'normal')
